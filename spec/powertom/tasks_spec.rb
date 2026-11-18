# frozen_string_literal: true

require "rake"
require "spec_helper"
require "powertom/tasks"

RSpec.describe "powertom:check Rake task" do
  it "is defined by the file shipped in the gem" do
    expect(Rake::Task.task_defined?("powertom:check")).to be(true)
  end
end
