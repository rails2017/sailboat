# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'shiprails/version'

Gem::Specification.new do |spec|
  spec.name          = "shiprails"
  spec.version       = Shiprails::VERSION
  spec.authors       = ["Zane Shannon"]
  spec.email         = ["zcs@smileslaughs.com"]

  spec.summary       = %q{Shiprails helps you deploy Rails to AWS ECS.}
  spec.description   = %q{Shiprails aims to provide Heroku's Ship APIs for AWS ECS.}
  spec.homepage      = "https://github.com/rails2017/shiprails"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", "~> 5"
  spec.add_dependency "aws-sdk", "~> 2"
  spec.add_dependency "thor", "~> 0.14"
  spec.add_dependency "s3_config", "~> 0.1.0"

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec"

  spec.executables << "port"
  spec.executables << "ship"

end
