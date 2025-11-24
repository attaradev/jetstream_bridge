# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::InboxProcessor do
  let(:mock_message_processor) { double('MessageProcessor') }
  let(:processor) { described_class.new(mock_message_processor) }
  let(:mock_nats_msg) { double('NATS::Message') }
  let(:ack_action) { JetstreamBridge::MessageProcessor::ActionResult.new(action: :ack, ctx: nil) }
  let(:nak_action) { JetstreamBridge::MessageProcessor::ActionResult.new(action: :nak, ctx: nil) }

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
      allow(mock_message_processor).to receive(:handle_message).and_return(ack_action)
      allow(mock_message_processor).to receive(:apply_action)
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
        allow(mock_message_processor).to receive(:handle_message).with(mock_inbox_message, auto_ack: false).and_return(ack_action)
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
          expect(mock_message_processor).to receive(:handle_message).with(mock_inbox_message, auto_ack: false).and_return(ack_action)
          processor.process(mock_nats_msg)
        end

        it 'persists post-processing state' do
          expect(mock_repository).to receive(:persist_post).with(mock_record)
          processor.process(mock_nats_msg)
        end

        it 'applies the action after persistence' do
          expect(mock_message_processor).to receive(:apply_action).with(mock_inbox_message, ack_action)
          processor.process(mock_nats_msg)
        end

        it 'returns true' do
          result = processor.process(mock_nats_msg)
          expect(result).to be true
        end
      end

      context 'when handler returns a NAK action' do
        before do
          allow(mock_message_processor).to receive(:handle_message).with(mock_inbox_message, auto_ack: false).and_return(nak_action)
          allow(mock_repository).to receive(:persist_failure)
        end

        it 'marks failure and applies action' do
          expect(mock_repository).to receive(:persist_failure).with(mock_record, kind_of(StandardError))
          expect(mock_message_processor).to receive(:apply_action).with(mock_inbox_message, nak_action)
          processor.process(mock_nats_msg)
        end

        it 'returns false' do
          result = processor.process(mock_nats_msg)
          expect(result).to be false
        end
      end

      context 'when processing fails' do
        let(:error) { StandardError.new('Processing failed') }

        before do
          allow(mock_message_processor).to receive(:handle_message).and_raise(error)
          allow(mock_repository).to receive(:persist_failure)
          allow(mock_message_processor).to receive(:safe_nak)
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

      it 'logs warning when inbox model is not ActiveRecord class' do
        expect(JetstreamBridge::Logging).to receive(:warn).with(
          /Inbox model.*is not an ActiveRecord model/,
          tag: 'JetstreamBridge::Consumer'
        )
        processor.process(mock_nats_msg)
      end

      it 'returns true even when processing directly' do
        result = processor.process(mock_nats_msg)
        expect(result).to be true
      end
    end

    context 'process_direct? when called explicitly with non-AR class' do
      let(:non_ar_class) { String }

      it 'handles non-AR class gracefully' do
        allow(JetstreamBridge.config).to receive(:inbox_model).and_return('String')
        allow(JetstreamBridge::ModelUtils).to receive(:constantize).and_return(non_ar_class)
        allow(JetstreamBridge::ModelUtils).to receive(:ar_class?).and_return(false)

        result = processor.process(mock_nats_msg)
        expect(result).to be true
      end
    end
  end

  describe 'error handling edge cases' do
    let(:inbox_model_class) { class_double('InboxEvent') }
    let(:mock_inbox_message) { instance_double('JetstreamBridge::InboxMessage', ack: true) }
    let(:mock_repository) { instance_double('JetstreamBridge::InboxRepository') }

    before do
      allow(JetstreamBridge.config).to receive(:inbox_model).and_return('InboxEvent')
      allow(JetstreamBridge::ModelUtils).to receive(:constantize).and_return(inbox_model_class)
      allow(JetstreamBridge::ModelUtils).to receive(:ar_class?).and_return(true)
      allow(JetstreamBridge::InboxMessage).to receive(:from_nats).and_return(mock_inbox_message)
      allow(JetstreamBridge::InboxRepository).to receive(:new).and_return(mock_repository)
      allow(mock_message_processor).to receive(:apply_action)
    end

    it 'handles error during already_processed? check' do
      mock_record = double('InboxRecord')
      allow(mock_repository).to receive(:find_or_build).and_return(mock_record)
      allow(mock_repository).to receive(:already_processed?).and_raise(StandardError, 'DB error')
      allow(mock_repository).to receive(:persist_failure)

      result = processor.process(mock_nats_msg)
      expect(result).to be false
    end

    it 'handles error during persist_pre' do
      mock_record = double('InboxRecord')
      allow(mock_repository).to receive(:find_or_build).and_return(mock_record)
      allow(mock_repository).to receive(:already_processed?).and_return(false)
      allow(mock_repository).to receive(:persist_pre).and_raise(StandardError, 'Persist error')
      allow(mock_repository).to receive(:persist_failure)

      result = processor.process(mock_nats_msg)
      expect(result).to be false
    end

    it 'handles error during persist_post' do
      mock_record = double('InboxRecord')
      allow(mock_repository).to receive(:find_or_build).and_return(mock_record)
      allow(mock_repository).to receive(:already_processed?).and_return(false)
      allow(mock_repository).to receive(:persist_pre)
      allow(mock_message_processor).to receive(:handle_message)
      allow(mock_repository).to receive(:persist_post).and_raise(StandardError, 'Post-persist error')
      allow(mock_repository).to receive(:persist_failure)

      result = processor.process(mock_nats_msg)
      expect(result).to be false
    end

    it 'logs error when processing fails' do
      mock_record = double('InboxRecord')
      allow(mock_repository).to receive(:find_or_build).and_return(mock_record)
      allow(mock_repository).to receive(:already_processed?).and_return(false)
      allow(mock_repository).to receive(:persist_pre)
      allow(mock_message_processor).to receive(:handle_message).and_raise(StandardError, 'Handler error')
      allow(mock_repository).to receive(:persist_failure)

      expect(JetstreamBridge::Logging).to receive(:error).with(
        /Inbox processing failed/,
        tag: 'JetstreamBridge::Consumer'
      )

      processor.process(mock_nats_msg)
    end

    it 'handles error when repo or record are nil' do
      # Make InboxRepository.new fail, which happens before record is assigned
      allow(JetstreamBridge::InboxRepository).to receive(:new).and_raise(StandardError, 'Repository init failed')

      expect(JetstreamBridge::Logging).to receive(:error).with(
        /Inbox processing failed/,
        tag: 'JetstreamBridge::Consumer'
      )

      # Should not attempt to call persist_failure since repo is nil
      result = processor.process(mock_nats_msg)
      expect(result).to be false
    end
  end

  describe '#process_direct? with ActiveRecord class' do
    let(:ar_class) { class_double('InboxEvent') }
    let(:processor_instance) { described_class.new(mock_message_processor) }

    it 'does not log warning when class is ActiveRecord' do
      # Simulate calling process_direct? with an AR class
      allow(JetstreamBridge::ModelUtils).to receive(:ar_class?).with(ar_class).and_return(true)

      expect(JetstreamBridge::Logging).not_to receive(:warn)
      expect(mock_message_processor).to receive(:handle_message).with(mock_nats_msg)

      result = processor_instance.send(:process_direct?, mock_nats_msg, ar_class)
      expect(result).to be true
    end
  end
end
