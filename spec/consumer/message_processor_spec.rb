# frozen_string_literal: true

require 'jetstream_bridge'
require 'oj'

RSpec.describe JetstreamBridge::MessageProcessor do
  let(:jts) { double('jetstream') }
  let(:handler) { double('handler') }
  let(:dlq) { instance_double(JetstreamBridge::DlqPublisher) }
  let(:processor) { described_class.new(jts, handler, dlq: dlq) }

  let(:metadata) do
    double('metadata', num_delivered: deliveries, sequence: 1, consumer: 'dur', stream: 'stream')
  end

  let(:msg) do
    double('msg',
           data: Oj.dump({ foo: 'bar' }),
           header: { 'nats-msg-id' => 'abc-123' },
           subject: 'test.subject',
           metadata: metadata,
           ack: nil,
           nak: nil)
  end

  after { JetstreamBridge.reset! }

  context 'when handler succeeds' do
    let(:deliveries) { 1 }

    it 'acks the message' do
      expect(handler).to receive(:call).with(Oj.load(msg.data, mode: :strict), msg.subject, deliveries)
      expect(msg).to receive(:ack)
      expect(dlq).not_to receive(:publish)
      processor.handle_message(msg)
    end
  end

  context 'when handler raises a standard error' do
    let(:deliveries) { 2 }

    it 'naks the message' do
      allow(handler).to receive(:call).and_raise(StandardError, 'boom')
      expect(msg).to receive(:nak)
      expect(dlq).not_to receive(:publish)
      processor.handle_message(msg)
    end
  end

  context 'when handler raises an unrecoverable error' do
    let(:deliveries) { 3 }

    it 'acks and publishes to the DLQ' do
      allow(handler).to receive(:call).and_raise(ArgumentError, 'bad')
      expect(msg).to receive(:ack)
      expect(dlq).to receive(:publish) do |m, ctx, reason:, error_class:, error_message:|
        expect(m).to eq(msg)
        expect(ctx.event_id).to eq('abc-123')
        expect(reason).to eq('unrecoverable')
        expect(error_class).to eq('ArgumentError')
        expect(error_message).to eq('bad')
      end
      processor.handle_message(msg)
    end
  end
end
