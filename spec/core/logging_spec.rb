# frozen_string_literal: true

require 'jetstream_bridge'
require 'logger'
require 'stringio'

RSpec.describe JetstreamBridge::Logging do
  after { JetstreamBridge.reset! }

  it 'uses configured logger' do
    io = StringIO.new
    custom_logger = Logger.new(io)
    JetstreamBridge.configure(logger: custom_logger)

    described_class.info('hello', tag: 'Spec')

    io.rewind
    expect(io.string).to include('[Spec] hello')
  end

  it 'logs debug messages' do
    io = StringIO.new
    custom_logger = Logger.new(io)
    JetstreamBridge.configure(logger: custom_logger)

    described_class.debug('dbg', tag: 'Spec')

    io.rewind
    expect(io.string).to include('[Spec] dbg')
  end
end
