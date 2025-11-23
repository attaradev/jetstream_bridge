# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::InboxProcessor do
  let(:mock_message_processor) { double('MessageProcessor', handle_message: true) }
  let(:processor) { described_class.new(mock_message_processor) }
  let(:mock_nats_msg) { double('NATS::Message') }

  describe '#initialize' do
    it 'stores the message processor' do
      expect(processor.instance_variable_get(:@processor)).to eq(mock_message_processor)
    end
  end

  describe '#process' do
    let(:inbox_model_class) { class_double('InboxEvent') }
    let(:mock_inbox_message) { instance_double('JetstreamBridge::InboxMessage', ack: true) }
    let(:mock_repository) { instance_double('JetstreamBridge::InboxRepository') }
    let(:mock_record) { double('InboxRecord') }

    before do
      allow(JetstreamBridge.config).to receive(:inbox_model).and_return('InboxEvent')
      allow(JetstreamBridge::ModelUtils).to receive(:constantize).and_return(inbox_model_class)
      allow(JetstreamBridge::InboxMessage).to receive(:from_nats).and_return(mock_inbox_message)
      allow(JetstreamBridge::InboxRepository).to receive(:new).and_return(mock_repository)
    end

    context 'when inbox model is not an ActiveRecord class' do
      before do
        allow(JetstreamBridge::ModelUtils).to receive(:ar_class?).and_return(false)
      end

      it 'processes message directly' do
        expect(mock_message_processor).to receive(:handle_message).with(mock_nats_msg)
        result = processor.process(mock_nats_msg)
        expect(result).to be true
      end

      it 'does not use repository' do
        expect(JetstreamBridge::InboxRepository).not_to receive(:new)
        processor.process(mock_nats_msg)
      end
    end

    context 'when inbox model is an ActiveRecord class' do
      before do
        allow(JetstreamBridge::ModelUtils).to receive(:ar_class?).and_return(true)
        allow(mock_repository).to receive(:find_or_build).and_return(mock_record)
        allow(mock_repository).to receive(:already_processed?).and_return(false)
        allow(mock_repository).to receive(:persist_pre)
        allow(mock_repository).to receive(:persist_post)
      end

      it 'creates inbox message from NATS message' do
        expect(JetstreamBridge::InboxMessage).to receive(:from_nats).with(mock_nats_msg)
        processor.process(mock_nats_msg)
      end

      it 'creates repository with inbox model class' do
        expect(JetstreamBridge::InboxRepository).to receive(:new).with(inbox_model_class)
        processor.process(mock_nats_msg)
      end

      it 'finds or builds record' do
        expect(mock_repository).to receive(:find_or_build).with(mock_inbox_message)
        processor.process(mock_nats_msg)
      end

      context 'when message already processed' do
        before do
          allow(mock_repository).to receive(:already_processed?).and_return(true)
        end

        it 'acks the message' do
          expect(mock_inbox_message).to receive(:ack)
          processor.process(mock_nats_msg)
        end

        it 'does not process message' do
          expect(mock_message_processor).not_to receive(:handle_message)
          processor.process(mock_nats_msg)
        end

        it 'returns true' do
          result = processor.process(mock_nats_msg)
          expect(result).to be true
        end
      end

      context 'when message not yet processed' do
        it 'persists pre-processing state' do
          expect(mock_repository).to receive(:persist_pre).with(mock_record, mock_inbox_message)
          processor.process(mock_nats_msg)
        end

        it 'handles the message' do
          expect(mock_message_processor).to receive(:handle_message).with(mock_inbox_message)
          processor.process(mock_nats_msg)
        end

        it 'persists post-processing state' do
          expect(mock_repository).to receive(:persist_post).with(mock_record)
          processor.process(mock_nats_msg)
        end

        it 'returns true' do
          result = processor.process(mock_nats_msg)
          expect(result).to be true
        end
      end

      context 'when processing fails' do
        let(:error) { StandardError.new('Processing failed') }

        before do
          allow(mock_message_processor).to receive(:handle_message).and_raise(error)
          allow(mock_repository).to receive(:persist_failure)
        end

        it 'persists failure to repository' do
          expect(mock_repository).to receive(:persist_failure).with(mock_record, error)
          processor.process(mock_nats_msg)
        end

        it 'returns false' do
          result = processor.process(mock_nats_msg)
          expect(result).to be false
        end

        it 'does not re-raise error' do
          expect { processor.process(mock_nats_msg) }.not_to raise_error
        end
      end
    end

    context 'process_direct? behavior' do
      let(:non_ar_class) { Class.new }

      before do
        allow(JetstreamBridge.config).to receive(:inbox_model).and_return('NonARClass')
        allow(JetstreamBridge::ModelUtils).to receive(:constantize).and_return(non_ar_class)
        allow(JetstreamBridge::ModelUtils).to receive(:ar_class?).and_return(false)
      end

      it 'processes message directly without repository' do
        expect(mock_message_processor).to receive(:handle_message).with(mock_nats_msg)
        expect(JetstreamBridge::InboxRepository).not_to receive(:new)
        result = processor.process(mock_nats_msg)
        expect(result).to be true
      end
    end
  end
end
