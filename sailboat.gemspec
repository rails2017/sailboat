# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'sailboat/version'

Gem::Specification.new do |spec|
  spec.name          = "sailboat"
  spec.version       = Sailboat::VERSION
  spec.authors       = ["Zane Shannon"]
  spec.email         = ["zcs@smileslaughs.com"]

  spec.summary       = %q{Sailboat helps you deploy Rails to AWS ECS.}
  spec.description   = %q{Sailboat aims to provide Heroku's CLI APIs for AWS ECS.}
  spec.homepage      = "https://github.com/rails2017/sailboat"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "aws-sdk", "~> 2"
  spec.add_dependency "thor", "~> 0.14"

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec"

  spec.executables << "sailboat"
end
