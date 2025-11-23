# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge/core/model_codec_setup'

RSpec.describe JetstreamBridge::ModelCodecSetup do
  describe '.ar_connected?' do
    context 'when ActiveRecord is connected' do
      before do
        allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
      end

      it 'returns true' do
        expect(described_class.ar_connected?).to be true
      end
    end

    context 'when ActiveRecord is not connected' do
      before do
        allow(ActiveRecord::Base).to receive(:connected?).and_return(false)
      end

      it 'returns false' do
        expect(described_class.ar_connected?).to be false
      end
    end

    context 'when ActiveRecord raises error' do
      before do
        allow(ActiveRecord::Base).to receive(:connected?).and_raise(StandardError)
      end

      it 'returns false' do
        expect(described_class.ar_connected?).to be false
      end
    end
  end

  describe '.table_exists_safely?' do
    let(:mock_klass) { double('ModelClass') }

    context 'when table exists' do
      before do
        allow(mock_klass).to receive(:table_exists?).and_return(true)
      end

      it 'returns true' do
        expect(described_class.table_exists_safely?(mock_klass)).to be true
      end
    end

    context 'when table does not exist' do
      before do
        allow(mock_klass).to receive(:table_exists?).and_return(false)
      end

      it 'returns false' do
        expect(described_class.table_exists_safely?(mock_klass)).to be false
      end
    end

    context 'when table_exists? raises error' do
      before do
        allow(mock_klass).to receive(:table_exists?).and_raise(StandardError)
      end

      it 'returns false' do
        expect(described_class.table_exists_safely?(mock_klass)).to be false
      end
    end
  end

  describe '.column?' do
    let(:mock_klass) do
      double('ModelClass', columns_hash: { 'payload' => double, 'headers' => double })
    end

    it 'returns true when column exists' do
      expect(described_class.column?(mock_klass, 'payload')).to be true
    end

    it 'returns false when column does not exist' do
      expect(described_class.column?(mock_klass, 'nonexistent')).to be false
    end

    context 'when columns_hash raises error' do
      before do
        allow(mock_klass).to receive(:columns_hash).and_raise(StandardError)
      end

      it 'returns false' do
        expect(described_class.column?(mock_klass, 'payload')).to be false
      end
    end
  end

  describe '.json_column?' do
    let(:mock_column) { double('Column', sql_type: 'json') }
    let(:mock_klass) do
      double('ModelClass', columns_hash: { 'payload' => mock_column })
    end

    context 'when column is json type' do
      it 'returns true for json' do
        allow(mock_column).to receive(:sql_type).and_return('json')
        expect(described_class.json_column?(mock_klass, 'payload')).to be true
      end

      it 'returns true for jsonb' do
        allow(mock_column).to receive(:sql_type).and_return('jsonb')
        expect(described_class.json_column?(mock_klass, 'payload')).to be true
      end

      it 'is case insensitive' do
        allow(mock_column).to receive(:sql_type).and_return('JSON')
        expect(described_class.json_column?(mock_klass, 'payload')).to be true
      end
    end

    context 'when column is not json type' do
      before do
        allow(mock_column).to receive(:sql_type).and_return('text')
      end

      it 'returns false' do
        expect(described_class.json_column?(mock_klass, 'payload')).to be false
      end
    end

    context 'when column fetch raises error' do
      before do
        allow(mock_klass).to receive(:columns_hash).and_raise(StandardError)
      end

      it 'returns false' do
        expect(described_class.json_column?(mock_klass, 'payload')).to be false
      end
    end
  end

  describe '.already_serialized?' do
    let(:serialized_type) { double('SerializedType') }
    let(:text_type) { double('TextType') }
    let(:mock_klass) do
      double('ModelClass', attribute_types: { 'payload' => serialized_type })
    end

    context 'when attribute is already serialized' do
      before do
        allow(serialized_type).to receive(:is_a?).with(ActiveRecord::Type::Serialized).and_return(true)
      end

      it 'returns true' do
        expect(described_class.already_serialized?(mock_klass, 'payload')).to be true
      end
    end

    context 'when attribute is not serialized' do
      before do
        allow(serialized_type).to receive(:is_a?).with(ActiveRecord::Type::Serialized).and_return(false)
      end

      it 'returns false' do
        expect(described_class.already_serialized?(mock_klass, 'payload')).to be false
      end
    end

    context 'when attribute does not exist' do
      let(:mock_klass) { double('ModelClass', attribute_types: {}) }

      it 'returns false' do
        expect(described_class.already_serialized?(mock_klass, 'nonexistent')).to be false
      end
    end

    context 'when attribute_types raises error' do
      before do
        allow(mock_klass).to receive(:attribute_types).and_raise(StandardError)
      end

      it 'returns false' do
        expect(described_class.already_serialized?(mock_klass, 'payload')).to be false
      end
    end
  end

  describe '.apply_to' do
    let(:mock_klass) do
      double('ModelClass',
             columns_hash: {
               'payload' => double(sql_type: 'text'),
               'headers' => double(sql_type: 'text')
             },
             attribute_types: {})
    end

    before do
      allow(described_class).to receive(:table_exists_safely?).and_return(true)
      allow(described_class).to receive(:column?).and_return(true)
      allow(described_class).to receive(:json_column?).and_return(false)
      allow(described_class).to receive(:already_serialized?).and_return(false)
      allow(mock_klass).to receive(:serialize)
    end

    it 'serializes payload column' do
      expect(mock_klass).to receive(:serialize).with(:payload, coder: Oj)
      described_class.apply_to(mock_klass)
    end

    it 'serializes headers column' do
      expect(mock_klass).to receive(:serialize).with(:headers, coder: Oj)
      described_class.apply_to(mock_klass)
    end

    context 'when table does not exist' do
      before do
        allow(described_class).to receive(:table_exists_safely?).and_return(false)
      end

      it 'does not serialize' do
        expect(mock_klass).not_to receive(:serialize)
        described_class.apply_to(mock_klass)
      end
    end

    context 'when column does not exist' do
      before do
        allow(described_class).to receive(:column?).with(mock_klass, 'payload').and_return(false)
        allow(described_class).to receive(:column?).with(mock_klass, 'headers').and_return(true)
      end

      it 'skips missing column' do
        expect(mock_klass).not_to receive(:serialize).with(:payload, anything)
        expect(mock_klass).to receive(:serialize).with(:headers, coder: Oj)
        described_class.apply_to(mock_klass)
      end
    end

    context 'when column is json type' do
      before do
        allow(described_class).to receive(:json_column?).and_return(true)
      end

      it 'does not serialize' do
        expect(mock_klass).not_to receive(:serialize)
        described_class.apply_to(mock_klass)
      end
    end

    context 'when column is already serialized' do
      before do
        allow(described_class).to receive(:already_serialized?).and_return(true)
      end

      it 'does not serialize' do
        expect(mock_klass).not_to receive(:serialize)
        described_class.apply_to(mock_klass)
      end
    end

    context 'when serialize raises ActiveRecord error' do
      before do
        allow(mock_klass).to receive(:serialize).and_raise(ActiveRecord::StatementInvalid)
      end

      it 'rescues and does not re-raise' do
        expect { described_class.apply_to(mock_klass) }.not_to raise_error
      end
    end

    context 'when serialize raises ConnectionNotEstablished' do
      before do
        allow(mock_klass).to receive(:serialize).and_raise(ActiveRecord::ConnectionNotEstablished)
      end

      it 'rescues and does not re-raise' do
        expect { described_class.apply_to(mock_klass) }.not_to raise_error
      end
    end

    context 'when serialize raises NoDatabaseError' do
      before do
        allow(mock_klass).to receive(:serialize).and_raise(ActiveRecord::NoDatabaseError)
      end

      it 'rescues and does not re-raise' do
        expect { described_class.apply_to(mock_klass) }.not_to raise_error
      end
    end
  end

  describe '.apply!' do
    before do
      allow(described_class).to receive(:ar_connected?).and_return(true)
      allow(described_class).to receive(:apply_to)
    end

    it 'applies to OutboxEvent' do
      expect(described_class).to receive(:apply_to).with(JetstreamBridge::OutboxEvent)
      described_class.apply!
    end

    it 'applies to InboxEvent' do
      expect(described_class).to receive(:apply_to).with(JetstreamBridge::InboxEvent)
      described_class.apply!
    end

    context 'when not connected' do
      before do
        allow(described_class).to receive(:ar_connected?).and_return(false)
      end

      it 'does not apply to any models' do
        expect(described_class).not_to receive(:apply_to)
        described_class.apply!
      end
    end
  end
end
