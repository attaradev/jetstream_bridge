# frozen_string_literal: true

begin
  require 'yard'

  YARD::Rake::YardocTask.new(:yard) do |t|
    t.files = ['lib/**/*.rb']
    t.options = ['--markup', 'markdown', '--readme', 'README.md']
    t.stats_options = ['--list-undoc']
  end

  desc 'Generate YARD documentation and display stats'
  task 'yard:stats' do
    sh 'bundle exec yard stats --list-undoc'
  end
rescue LoadError
  # YARD not available
end
