require 'rubygems'
require 'rake/gempackagetask'
require 'fileutils'

def read_version
  File.open('lib/ruined/ruinmain.rb').each_line do |x|
    m = /RUINED_VERSION[^']+'(.+?)'/.match(x)
    if m
      return m[1]
    end
  end
  nil
end

desc "Default Task"
task :default => [ :package ]

spec = Gem::Specification.new do |s|
  s.authors = 'arton'
  s.email = 'artonx@gmail.com'
  s.platform = Gem::Platform::RUBY
  s.required_ruby_version = '>= 1.9.1'
  s.summary = 'Ruby UI Debugger'
  s.name = 'ruined'
  s.homepage = 'http://github.com/arton/ruined'
  s.version = read_version
  s.requirements << 'none'
  s.require_path = 'lib'
  files = FileList['lib/ruined/*.rb', 'lib/uined*.rb', 'test/*.rb',
                   'lib/ruined/index.html', 'lib/ruined/html/**/*.html', 
                   'lib/ruined/css/**/*.css', 'lib/ruined/css/**/*.png',
                   'lib/ruined/js/**/*.js',
                   '*.txt', 'BSDL', 'ChangeLog']
  s.files = files
  s.test_file = 'test/test.rb'
  s.description = <<EOD
ruined is Ruby Source Level Debugger for educational purpose.
EOD
end

Rake::GemPackageTask.new(spec) do |pkg|
  pkg.gem_spec = spec
  pkg.need_zip = false
  pkg.need_tar = false
end

