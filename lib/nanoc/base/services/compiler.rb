module Nanoc::Int
  # Responsible for compiling a site’s item representations.
  #
  # The compilation process makes use of notifications (see
  # {Nanoc::Int::NotificationCenter}) to track dependencies between items,
  # layouts, etc. The following notifications are used:
  #
  # * `compilation_started` — indicates that the compiler has started
  #   compiling this item representation. Has one argument: the item
  #   representation itself. Only one item can be compiled at a given moment;
  #   therefore, it is not possible to get two consecutive
  #   `compilation_started` notifications without also getting a
  #   `compilation_ended` notification in between them.
  #
  # * `compilation_ended` — indicates that the compiler has finished compiling
  #   this item representation (either successfully or with failure). Has one
  #   argument: the item representation itself.
  #
  # @api private
  class Compiler
    # Provides common functionality for accesing “context” of an item that is being compiled.
    class CompilationContext
      attr_reader :site
      attr_reader :compiled_content_cache
      attr_reader :snapshot_repo

      def initialize(action_provider:, reps:, site:, compiled_content_cache:, snapshot_repo:)
        @action_provider = action_provider
        @reps = reps
        @site = site
        @compiled_content_cache = compiled_content_cache
        @snapshot_repo = snapshot_repo
      end

      def filter_name_and_args_for_layout(layout)
        mem = @action_provider.memory_for(layout)
        if mem.nil? || mem.size != 1 || !mem[0].is_a?(Nanoc::Int::ProcessingActions::Filter)
          raise Nanoc::Int::Errors::UndefinedFilterForLayout.new(layout)
        end
        [mem[0].filter_name, mem[0].params]
      end

      def create_view_context(dependency_tracker)
        Nanoc::ViewContext.new(
          reps: @reps,
          items: @site.items,
          dependency_tracker: dependency_tracker,
          compilation_context: self,
          snapshot_repo: @snapshot_repo,
        )
      end

      def assigns_for(rep, dependency_tracker)
        last_content = @snapshot_repo.get(rep, :last)
        content_or_filename_assigns =
          if last_content.binary?
            { filename: last_content.filename }
          else
            { content: last_content.string }
          end

        view_context = create_view_context(dependency_tracker)

        content_or_filename_assigns.merge(
          item: Nanoc::ItemWithRepsView.new(rep.item, view_context),
          rep: Nanoc::ItemRepView.new(rep, view_context),
          item_rep: Nanoc::ItemRepView.new(rep, view_context),
          items: Nanoc::ItemCollectionWithRepsView.new(@site.items, view_context),
          layouts: Nanoc::LayoutCollectionView.new(@site.layouts, view_context),
          config: Nanoc::ConfigView.new(@site.config, view_context),
        )
      end
    end

    module Stages
      class Preprocess
        def initialize(action_provider:, site:, dependency_store:, checksum_store:)
          @action_provider = action_provider
          @site = site
          @dependency_store = dependency_store
          @checksum_store = checksum_store
        end

        def run
          @action_provider.preprocess(@site)

          @dependency_store.objects = @site.items.to_a + @site.layouts.to_a
          @checksum_store.objects = @site.items.to_a + @site.layouts.to_a + @site.code_snippets + [@site.config]

          @site.freeze
        end
      end

      class Prune
        def initialize(config:, reps:)
          @config = config
          @reps = reps
        end

        def run
          if @config[:prune][:auto_prune]
            Nanoc::Pruner.new(@config, @reps, exclude: prune_config_exclude).run
          end
        end

        private

        def prune_config
          @config[:prune] || {}
        end

        def prune_config_exclude
          prune_config[:exclude] || {}
        end
      end

      class DetermineOutdatedness
        def initialize(reps:, outdatedness_checker:, outdatedness_store:)
          @reps = reps
          @outdatedness_checker = outdatedness_checker
          @outdatedness_store = outdatedness_store
        end

        def run
          outdated_reps_tmp = @reps.select do |r|
            @outdatedness_store.include?(r) || @outdatedness_checker.outdated?(r)
          end

          outdated_items = outdated_reps_tmp.map(&:item).uniq
          outdated_reps = Set.new(outdated_items.flat_map { |i| @reps[i] })

          outdated_reps.each { |r| @outdatedness_store.add(r) }

          yield(outdated_items)
        end
      end

      class CompileReps
        def initialize(outdatedness_store:, dependency_store:, action_provider:, compilation_context:, compiled_content_cache:)
          @outdatedness_store = outdatedness_store
          @dependency_store = dependency_store
          @action_provider = action_provider
          @compilation_context = compilation_context
          @compiled_content_cache = compiled_content_cache
        end

        def run
          selector = Nanoc::Int::ItemRepSelector.new(@outdatedness_store.to_a)
          selector.each do |rep|
            handle_errors_while(rep) { compile_rep(rep, is_outdated: @outdatedness_store.include?(rep)) }
          end
        ensure
          @outdatedness_store.store
          @compiled_content_cache.store
        end

        private

        def handle_errors_while(item_rep)
          yield
        rescue => e
          raise Nanoc::Int::Errors::CompilationError.new(e, item_rep)
        end

        def compile_rep(rep, is_outdated:)
          item_rep_compiler.run(rep, is_outdated: is_outdated)
        end

        def item_rep_compiler
          @_item_rep_compiler ||= begin
            recalculate_phase = Phases::Recalculate.new(
              action_provider: @action_provider,
              dependency_store: @dependency_store,
              compilation_context: @compilation_context,
            )

            cache_phase = Phases::Cache.new(
              compiled_content_cache: @compiled_content_cache,
              snapshot_repo: @compilation_context.snapshot_repo,
              wrapped: recalculate_phase,
            )

            resume_phase = Phases::Resume.new(
              wrapped: cache_phase,
            )

            write_phase = Phases::Write.new(
              snapshot_repo: @compilation_context.snapshot_repo,
              wrapped: resume_phase,
            )

            mark_done_phase = Phases::MarkDone.new(
              wrapped: write_phase,
              outdatedness_store: @outdatedness_store,
            )

            mark_done_phase
          end
        end
      end

      class Cleanup
        def initialize(config)
          @config = config
        end

        def run
          cleanup_temps(Nanoc::Filter::TMP_BINARY_ITEMS_DIR)
          cleanup_temps(Nanoc::Int::ItemRepWriter::TMP_TEXT_ITEMS_DIR)
          cleanup_unused_stores
        end

        private

        def cleanup_temps(dir)
          Nanoc::Int::TempFilenameFactory.instance.cleanup(dir)
        end

        def cleanup_unused_stores
          used_paths = @config.output_dirs.map { |d| Nanoc::Int::Store.tmp_path_prefix(d) }
          all_paths = Dir.glob('tmp/nanoc/*')
          (all_paths - used_paths).each do |obsolete_path|
            FileUtils.rm_rf(obsolete_path)
          end
        end
      end
    end

    include Nanoc::Int::ContractsSupport

    # @api private
    attr_reader :site

    # @api private
    attr_reader :compiled_content_cache

    # @api private
    attr_reader :checksum_store

    # @api private
    attr_reader :rule_memory_store

    # @api private
    attr_reader :action_provider

    # @api private
    attr_reader :dependency_store

    # @api private
    attr_reader :outdatedness_checker

    # @api private
    attr_reader :reps

    # @api private
    attr_reader :outdatedness_store

    # @api private
    attr_reader :snapshot_repo

    def initialize(site, compiled_content_cache:, checksum_store:, rule_memory_store:, action_provider:, dependency_store:, outdatedness_checker:, reps:, outdatedness_store:)
      @site = site

      @compiled_content_cache = compiled_content_cache
      @checksum_store         = checksum_store
      @rule_memory_store      = rule_memory_store
      @dependency_store       = dependency_store
      @outdatedness_checker   = outdatedness_checker
      @reps                   = reps
      @action_provider        = action_provider
      @outdatedness_store     = outdatedness_store

      # TODO: inject
      @snapshot_repo = Nanoc::Int::SnapshotRepo.new
    end

    def run_all
      preprocess_stage.run
      build_reps
      prune_stage.run
      load_stores
      determine_outdatedness
      forget_dependencies_if_needed
      store
      compile_reps
      store_output_state
      @action_provider.postprocess(@site, @reps)
    ensure
      cleanup_stage.run
    end

    def load_stores
      stores.each(&:load)
    end

    # TODO: rename to store_preprocessed_state
    def store
      # Calculate rule memory
      (@reps.to_a + @site.layouts.to_a).each do |obj|
        rule_memory_store[obj] = action_provider.memory_for(obj).serialize
      end

      # Calculate checksums
      objects_to_checksum =
        site.items.to_a + site.layouts.to_a + site.code_snippets + [site.config]
      objects_to_checksum.each { |obj| checksum_store.add(obj) }

      # Store
      checksum_store.store
      rule_memory_store.store
    end

    def store_output_state
      @dependency_store.store
    end

    def build_reps
      builder = Nanoc::Int::ItemRepBuilder.new(
        site, action_provider, @reps
      )
      builder.run
    end

    def compilation_context
      @_compilation_context ||= CompilationContext.new(
        action_provider: action_provider,
        reps: @reps,
        site: @site,
        compiled_content_cache: compiled_content_cache,
        snapshot_repo: snapshot_repo,
      )
    end

    private

    def preprocess_stage
      @_preprocess_stage ||= Stages::Preprocess.new(
        action_provider: action_provider,
        site: site,
        dependency_store: dependency_store,
        checksum_store: checksum_store,
      )
    end

    def prune_stage
      @_prune_stage ||= Stages::Prune.new(
        config: site.config,
        reps: reps,
      )
    end

    def determine_outdatedness_stage
      @_determine_outdatedness_stage ||= Stages::DetermineOutdatedness.new(
        reps: reps,
        outdatedness_checker: outdatedness_checker,
        outdatedness_store: outdatedness_store,
      )
    end

    def compile_reps_stage
      @_compile_reps_stage ||= Stages::CompileReps.new(
        outdatedness_store: @outdatedness_store,
        dependency_store: @dependency_store,
        action_provider: action_provider,
        compilation_context: compilation_context,
        compiled_content_cache: compiled_content_cache,
      )
    end

    def cleanup_stage
      @_cleanup_stage ||= Stages::Cleanup.new(site.config)
    end

    def determine_outdatedness
      determine_outdatedness_stage.run do |outdated_items|
        @outdated_items = outdated_items
      end
    end

    def forget_dependencies_if_needed
      @outdated_items.each { |i| @dependency_store.forget_dependencies_for(i) }
    end

    def compile_reps
      compile_reps_stage.run
    end

    # Returns all stores that can load/store data that can be used for
    # compilation.
    def stores
      [
        checksum_store,
        compiled_content_cache,
        @dependency_store,
        rule_memory_store,
        @outdatedness_store,
      ]
    end
  end
end
