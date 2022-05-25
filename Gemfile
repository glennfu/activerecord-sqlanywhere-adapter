# frozen_string_literal: true

source "https://rubygems.org"

git_source(:github) { |repo| "https://github.com/#{repo}.git" }

gemspec

gem "sqlanywhere2", github: "Unact/sqlanywhere2", branch: "master"

group :development do
  gem "rubocop", require: false
  gem "rubocop-performance", require: false

  gem "byebug"
end
