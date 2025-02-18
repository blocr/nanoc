# frozen_string_literal: true

require_relative 'lib/nanoc/tilt/version'

Gem::Specification.new do |s|
  s.name        = 'nanoc-tilt'
  s.version     = Nanoc::Tilt::VERSION
  s.homepage    = 'https://nanoc.ws/'
  s.summary     = 'Tilt filter for Nanoc'
  s.description = 'Provides a :tilt filter for Nanoc'
  s.author      = 'Denis Defreyne'
  s.email       = 'denis+rubygems@denis.ws'
  s.license     = 'MIT'

  s.files         = ['NEWS.md', 'README.md'] + Dir['lib/**/*.rb']
  s.require_paths = ['lib']

  s.required_ruby_version = '>= 2.7'

  s.add_runtime_dependency('nanoc-core', '~> 4.11', '>= 4.11.14')
  s.add_runtime_dependency('tilt', '~> 2.0')
  s.metadata['rubygems_mfa_required'] = 'true'
end
