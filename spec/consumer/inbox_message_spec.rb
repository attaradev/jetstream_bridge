# frozen_string_literal: true

require 'jetstream_bridge'
require 'oj'

RSpec.describe JetstreamBridge::InboxMessage do
  let(:metadata) do
    double('metadata',
           stream_sequence: 1,
           num_delivered: 2,
           stream: 'test',
           consumer: 'durable')
  end

  let(:nats_msg) do
    double('nats-msg',
           subject: 'inbox.subject',
           data: Oj.dump({ foo: 'bar' }),
           header: { 'nats-msg-id' => 'id-123' },
           metadata: metadata,
           ack: nil,
           nak: nil)
  end

  subject(:msg) { described_class.from_nats(nats_msg) }

  it 'delegates ack to the underlying message' do
    expect(nats_msg).to receive(:ack)
    msg.ack
  end

  it 'delegates nak to the underlying message' do
    expect(nats_msg).to receive(:nak).with(:foo)
    msg.nak(:foo)
  end
end
