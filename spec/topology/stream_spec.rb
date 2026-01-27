# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::Stream do
  let(:mock_jts) { double('NATS::JetStream') }
  let(:stream_name) { 'test_stream' }
  let(:subjects) { ['test.subject.one', 'test.subject.two'] }

  describe '.ensure!' do
    context 'when stream does not exist' do
      before do
        allow(mock_jts).to receive(:stream_info).and_raise(
          NATS::JetStream::Error.new('stream not found')
        )
        allow(JetstreamBridge::OverlapGuard).to receive(:partition_allowed)
          .and_return([subjects, []])
        allow(mock_jts).to receive(:add_stream)
      end

      it 'creates the stream with correct parameters' do
        expect(mock_jts).to receive(:add_stream).with(
          hash_including(
            name: stream_name,
            subjects: subjects,
            retention: 'workqueue',
            storage: 'file'
          )
        )
        described_class.ensure!(mock_jts, stream_name, subjects)
      end

      it 'normalizes subject list' do
        messy_subjects = ['  test.one  ', nil, '', 'test.two', 'test.one']
        allow(JetstreamBridge::OverlapGuard).to receive(:partition_allowed)
          .and_return([['test.one', 'test.two'], []])

        expect(mock_jts).to receive(:add_stream).with(
          hash_including(subjects: ['test.one', 'test.two'])
        )
        described_class.ensure!(mock_jts, stream_name, messy_subjects)
      end

      it 'raises error when subjects are empty' do
        expect do
          described_class.ensure!(mock_jts, stream_name, [])
        end.to raise_error(ArgumentError, /subjects must not be empty/)
      end

      context 'when all subjects are blocked by overlap' do
        before do
          allow(JetstreamBridge::OverlapGuard).to receive(:partition_allowed)
            .and_return([[], subjects])
        end

        it 'does not create the stream' do
          expect(mock_jts).not_to receive(:add_stream)
          described_class.ensure!(mock_jts, stream_name, subjects)
        end
      end

      context 'when some subjects are allowed' do
        let(:allowed) { ['test.subject.one'] }
        let(:blocked) { ['test.subject.two'] }

        before do
          allow(JetstreamBridge::OverlapGuard).to receive(:partition_allowed)
            .and_return([allowed, blocked])
          allow(mock_jts).to receive(:add_stream)
        end

        it 'creates stream with only allowed subjects' do
          expect(mock_jts).to receive(:add_stream).with(
            hash_including(subjects: allowed)
          )
          described_class.ensure!(mock_jts, stream_name, subjects)
        end
      end
    end

    context 'when stream exists' do
      let(:mock_config) do
        double('StreamConfig',
               subjects: ['existing.subject'],
               retention: 'workqueue',
               storage: 'file')
      end
      let(:mock_info) { double('StreamInfo', config: mock_config) }

      before do
        allow(mock_jts).to receive(:stream_info).and_return(mock_info)
      end

      context 'with matching config and subjects covered' do
        before do
          allow(JetstreamBridge::StreamSupport).to receive(:missing_subjects)
            .and_return([])
        end

        it 'does not update the stream' do
          expect(mock_jts).not_to receive(:update_stream)
          described_class.ensure!(mock_jts, stream_name, ['existing.subject'])
        end
      end

      context 'with new subjects to add' do
        let(:new_subjects) { ['new.subject'] }

        before do
          allow(JetstreamBridge::StreamSupport).to receive(:missing_subjects)
            .and_return(new_subjects)
          allow(JetstreamBridge::OverlapGuard).to receive(:partition_allowed)
            .and_return([new_subjects, []])
          allow(JetstreamBridge::OverlapGuard).to receive(:check!)
          allow(mock_jts).to receive(:update_stream)
        end

        it 'updates stream with merged subjects' do
          expect(mock_jts).to receive(:update_stream).with(
            hash_including(
              name: stream_name,
              subjects: ['existing.subject', 'new.subject']
            )
          )
          described_class.ensure!(mock_jts, stream_name, ['existing.subject', 'new.subject'])
        end

        it 'checks for overlaps before updating' do
          expect(JetstreamBridge::OverlapGuard).to receive(:check!)
            .with(mock_jts, stream_name, ['existing.subject', 'new.subject'])
          described_class.ensure!(mock_jts, stream_name, ['existing.subject', 'new.subject'])
        end

        it 'does not pass retention on update' do
          expect(mock_jts).to receive(:update_stream).with(
            hash_not_including(:retention)
          )
          described_class.ensure!(mock_jts, stream_name, ['existing.subject', 'new.subject'])
        end
      end

      context 'with new subjects but all blocked by overlap' do
        let(:new_subjects) { ['new.subject'] }

        before do
          allow(JetstreamBridge::StreamSupport).to receive(:missing_subjects)
            .and_return(new_subjects)
          allow(JetstreamBridge::OverlapGuard).to receive(:partition_allowed)
            .and_return([[], new_subjects])
        end

        it 'does not update the stream' do
          expect(mock_jts).not_to receive(:update_stream)
          described_class.ensure!(mock_jts, stream_name, ['existing.subject', 'new.subject'])
        end
      end

      context 'with different storage' do
        let(:mock_config) do
          double('StreamConfig',
                 subjects: ['test.subject'],
                 retention: 'workqueue',
                 storage: 'memory')
        end

        before do
          allow(JetstreamBridge::StreamSupport).to receive(:missing_subjects)
            .and_return([])
          allow(mock_jts).to receive(:update_stream)
        end

        it 'updates storage to file' do
          expect(mock_jts).to receive(:update_stream).with(
            hash_including(storage: 'file')
          )
          described_class.ensure!(mock_jts, stream_name, ['test.subject'])
        end
      end

      context 'with different retention' do
        let(:mock_config) do
          double('StreamConfig',
                 subjects: ['test.subject'],
                 retention: 'limits',
                 storage: 'file')
        end

        before do
          allow(JetstreamBridge::StreamSupport).to receive(:missing_subjects)
            .and_return([])
        end

        it 'does not update retention (immutable)' do
          expect(mock_jts).not_to receive(:update_stream)
          described_class.ensure!(mock_jts, stream_name, ['test.subject'])
        end
      end
    end

    context 'overlap error handling with retry' do
      before do
        allow(mock_jts).to receive(:stream_info).and_raise(
          NATS::JetStream::Error.new('stream not found')
        )
        allow(JetstreamBridge::OverlapGuard).to receive(:partition_allowed)
          .and_return([subjects, []])
      end

      context 'when overlap error occurs then succeeds' do
        before do
          @attempt = 0
          allow(mock_jts).to receive(:add_stream) do
            @attempt += 1
            raise NATS::JetStream::Error, 'subjects overlap' if @attempt == 1

            true
          end
          allow_any_instance_of(Object).to receive(:sleep)
        end

        it 'retries and eventually succeeds' do
          expect(mock_jts).to receive(:add_stream).twice
          described_class.ensure!(mock_jts, stream_name, subjects)
        end
      end

      context 'when overlap error persists' do
        before do
          allow(mock_jts).to receive(:add_stream)
            .and_raise(NATS::JetStream::Error.new('subjects overlap with err_code=10065'))
          allow_any_instance_of(Object).to receive(:sleep)
        end

        it 'retries max times then gives up' do
          expect(mock_jts).to receive(:add_stream).exactly(4).times # initial + 3 retries
          result = described_class.ensure!(mock_jts, stream_name, subjects)
          expect(result).to be_nil
        end
      end

      context 'when non-overlap error occurs' do
        before do
          allow(mock_jts).to receive(:add_stream)
            .and_raise(NATS::JetStream::Error.new('connection failed'))
        end

        it 'does not retry and re-raises error' do
          expect(mock_jts).to receive(:add_stream).once
          expect do
            described_class.ensure!(mock_jts, stream_name, subjects)
          end.to raise_error(NATS::JetStream::Error, /connection failed/)
        end
      end
    end

    context 'stream_info returns 404 error' do
      before do
        allow(mock_jts).to receive(:stream_info)
          .and_raise(NATS::JetStream::Error.new('404 stream not found'))
        allow(JetstreamBridge::OverlapGuard).to receive(:partition_allowed)
          .and_return([subjects, []])
        allow(mock_jts).to receive(:add_stream)
      end

      it 'treats as stream not found and creates stream' do
        expect(mock_jts).to receive(:add_stream)
        described_class.ensure!(mock_jts, stream_name, subjects)
      end
    end

    context 'stream_info returns other error' do
      before do
        allow(mock_jts).to receive(:stream_info)
          .and_raise(NATS::JetStream::Error.new('timeout'))
      end

      it 're-raises the error' do
        expect do
          described_class.ensure!(mock_jts, stream_name, subjects)
        end.to raise_error(NATS::JetStream::Error, /timeout/)
      end
    end
  end

  describe 'constants' do
    it 'has correct RETENTION value' do
      expect(described_class::RETENTION).to eq('workqueue')
    end

    it 'has correct STORAGE value' do
      expect(described_class::STORAGE).to eq('file')
    end
  end

end
