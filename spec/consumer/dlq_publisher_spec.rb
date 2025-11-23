# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::DlqPublisher do
  let(:jts) { double('JetStream') }
  let(:dlq_publisher) { described_class.new(jts) }

  let(:msg) do
    double(
      'Message',
      data: '{"order_id":123}',
      header: { 'content-type' => 'application/json' }
    )
  end

  let(:ctx) do
    double(
      event_id: 'evt-123',
      deliveries: 3,
      subject: 'test.orders.sync',
      seq: 456,
      consumer: 'test-consumer',
      stream: 'TEST_STREAM'
    )
  end

  let(:config) do
    double(
      use_dlq: true,
      dlq_subject: 'test.dlq'
    )
  end

  before do
    allow(JetstreamBridge).to receive(:config).and_return(config)
    allow(jts).to receive(:publish)
  end

  describe '#publish' do
    let(:reason) { 'max_deliveries_exceeded' }
    let(:error_class) { 'StandardError' }
    let(:error_message) { 'Processing failed' }

    context 'when DLQ is enabled' do
      it 'publishes message to DLQ subject' do
        dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)

        expect(jts).to have_received(:publish).with(
          'test.dlq',
          '{"order_id":123}',
          hash_including(:header)
        )
      end

      it 'includes original message data' do
        dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)

        expect(jts).to have_received(:publish).with(
          anything,
          '{"order_id":123}',
          anything
        )
      end

      it 'adds dead letter headers' do
        dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)

        expect(jts).to have_received(:publish) do |_subject, _data, opts|
          headers = opts[:header]
          expect(headers['x-dead-letter']).to eq('true')
          expect(headers['x-dlq-reason']).to eq(reason)
          expect(headers['x-deliveries']).to eq('3')
        end
      end

      it 'preserves original headers' do
        dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)

        expect(jts).to have_received(:publish) do |_subject, _data, opts|
          headers = opts[:header]
          expect(headers['content-type']).to eq('application/json')
        end
      end

      it 'includes DLQ context envelope as JSON' do
        freeze_time = Time.parse('2025-01-01 12:00:00 UTC')
        allow(Time).to receive_message_chain(:now, :utc, :iso8601).and_return(freeze_time.iso8601)

        dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)

        expect(jts).to have_received(:publish) do |_subject, _data, opts|
          headers = opts[:header]
          context = Oj.load(headers['x-dlq-context'])

          expect(context['event_id']).to eq('evt-123')
          expect(context['reason']).to eq(reason)
          expect(context['error_class']).to eq(error_class)
          expect(context['error_message']).to eq(error_message)
          expect(context['deliveries']).to eq(3)
          expect(context['original_subject']).to eq('test.orders.sync')
          expect(context['sequence']).to eq(456)
          expect(context['consumer']).to eq('test-consumer')
          expect(context['stream']).to eq('TEST_STREAM')
          expect(context['published_at']).to eq(freeze_time.iso8601)
        end
      end

      it 'returns true on success' do
        result = dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)
        expect(result).to be true
      end

      context 'when message has no headers' do
        before do
          allow(msg).to receive(:header).and_return(nil)
        end

        it 'creates new headers' do
          dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)

          expect(jts).to have_received(:publish) do |_subject, _data, opts|
            headers = opts[:header]
            expect(headers).to be_a(Hash)
            expect(headers['x-dead-letter']).to eq('true')
          end
        end
      end

      context 'when publish fails' do
        before do
          allow(jts).to receive(:publish).and_raise(StandardError, 'Network error')
          allow(JetstreamBridge::Logging).to receive(:error)
        end

        it 'logs error' do
          dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)

          expect(JetstreamBridge::Logging).to have_received(:error).with(
            /DLQ publish failed event_id=evt-123.*Network error/,
            tag: 'JetstreamBridge::Consumer'
          )
        end

        it 'returns false' do
          result = dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)
          expect(result).to be false
        end

        it 'does not re-raise error' do
          expect do
            dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)
          end.not_to raise_error
        end
      end
    end

    context 'when DLQ is disabled' do
      before do
        allow(config).to receive(:use_dlq).and_return(false)
      end

      it 'does not publish to DLQ' do
        dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)
        expect(jts).not_to have_received(:publish)
      end

      it 'returns true immediately' do
        result = dlq_publisher.publish(msg, ctx, reason: reason, error_class: error_class, error_message: error_message)
        expect(result).to be true
      end
    end
  end

  describe 'error reason handling' do
    it 'handles max_deliveries_exceeded reason' do
      dlq_publisher.publish(
        msg,
        ctx,
        reason: 'max_deliveries_exceeded',
        error_class: 'StandardError',
        error_message: 'Too many attempts'
      )

      expect(jts).to have_received(:publish) do |_subject, _data, opts|
        expect(opts[:header]['x-dlq-reason']).to eq('max_deliveries_exceeded')
      end
    end

    it 'handles unrecoverable_error reason' do
      dlq_publisher.publish(
        msg,
        ctx,
        reason: 'unrecoverable_error',
        error_class: 'JetstreamBridge::UnrecoverableError',
        error_message: 'Cannot process'
      )

      expect(jts).to have_received(:publish) do |_subject, _data, opts|
        expect(opts[:header]['x-dlq-reason']).to eq('unrecoverable_error')
      end
    end
  end

  describe 'complex error messages' do
    it 'handles error messages with special characters' do
      dlq_publisher.publish(
        msg,
        ctx,
        reason: 'processing_error',
        error_class: 'RuntimeError',
        error_message: 'Failed: "value" is <nil> & invalid'
      )

      expect(jts).to have_received(:publish) do |_subject, _data, opts|
        context = Oj.load(opts[:header]['x-dlq-context'])
        expect(context['error_message']).to eq('Failed: "value" is <nil> & invalid')
      end
    end

    it 'handles very long error messages' do
      long_message = 'x' * 10_000

      dlq_publisher.publish(
        msg,
        ctx,
        reason: 'processing_error',
        error_class: 'RuntimeError',
        error_message: long_message
      )

      expect(jts).to have_received(:publish) do |_subject, _data, opts|
        context = Oj.load(opts[:header]['x-dlq-context'])
        expect(context['error_message']).to eq(long_message)
      end
    end
  end
end
