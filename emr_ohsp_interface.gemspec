$:.push File.expand_path('lib', __dir__)

# Maintain your gem's version:
require 'emr_ohsp_interface/version'

# Describe your gem and declare its dependencies:
Gem::Specification.new do |spec|
  spec.name        = 'emr_ohsp_interface'
  spec.version     = EmrOhspInterface::VERSION
  spec.authors     = ['Justin Manda, Petros Kayange, Dominic Kasanga']
  spec.email       = ['justinmandah@gmail.com, kayangepetros@gmail.com, dominickasanga@gmail.com']
  spec.homepage    = 'https://github.com/LUKEINTERNATIONAL/emr_OHSP_interface'
  spec.summary     = 'This in a gem that facilitates interfacing of EMR, One Health Surveillance Platform and Lims' 
  # spec.description = "TODO: Description of EmrOhspInterface."
  spec.license     = 'MIT'

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  
  spec.metadata['homepage_uri'] = spec.homepage

  spec.files = Dir['{app,config,db,lib}/**/*', 'MIT-LICENSE', 'Rakefile', 'README.md']

  spec.add_dependency 'rails', '~> 8.0'


  spec.add_development_dependency 'mysql2', '~> 0'
  spec.add_development_dependency 'rest-client','~> 2.1'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'sqlite3', '>= 1.3.6', '~> 1.3'
end
