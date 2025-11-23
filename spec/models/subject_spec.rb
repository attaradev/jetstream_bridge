# frozen_string_literal: true

require 'jetstream_bridge/models/subject'

RSpec.describe JetstreamBridge::Models::Subject do
  describe '.new' do
    it 'creates a subject with valid value' do
      subject = described_class.new('dev.app1.sync.app2')

      expect(subject.to_s).to eq('dev.app1.sync.app2')
    end

    it 'validates subject format' do
      expect { described_class.new('invalid subject with spaces') }.to raise_error(ArgumentError, /invalid.*format/i)
    end

    it 'rejects empty subject' do
      expect { described_class.new('') }.to raise_error(ArgumentError)
    end

    it 'rejects nil subject' do
      expect { described_class.new(nil) }.to raise_error(ArgumentError)
    end

    it 'accepts subject with multiple tokens' do
      subject = described_class.new('env.source.sync.destination.extra')

      expect(subject.to_s).to eq('env.source.sync.destination.extra')
    end
  end

  describe '.source' do
    it 'creates a source subject with environment, app name, and destination' do
      subject = described_class.source(env: 'production', app_name: 'orders', dest: 'warehouse')

      expect(subject.to_s).to eq('production.orders.sync.warehouse')
    end

    it 'works with development environment' do
      subject = described_class.source(env: 'dev', app_name: 'users', dest: 'notifications')

      expect(subject.to_s).to eq('dev.users.sync.notifications')
    end

    it 'handles underscored app names' do
      subject = described_class.source(env: 'staging', app_name: 'user_service', dest: 'email_service')

      expect(subject.to_s).to eq('staging.user_service.sync.email_service')
    end
  end

  describe '.destination' do
    it 'creates a destination subject with environment, source, and app name' do
      subject = described_class.destination(env: 'production', source: 'orders', app_name: 'warehouse')

      expect(subject.to_s).to eq('production.orders.sync.warehouse')
    end

    it 'maintains consistency with source subject' do
      source_subj = described_class.source(env: 'dev', app_name: 'app1', dest: 'app2')
      dest_subj = described_class.destination(env: 'dev', source: 'app1', app_name: 'app2')

      expect(source_subj.to_s).to eq(dest_subj.to_s)
    end
  end

  describe '#matches?' do
    let(:subject) { described_class.new('production.orders.sync.warehouse') }

    it 'matches exact subject' do
      expect(subject.matches?('production.orders.sync.warehouse')).to be true
    end

    it 'matches wildcard patterns' do
      expect(subject.matches?('production.orders.sync.*')).to be true
      expect(subject.matches?('production.*.sync.warehouse')).to be true
      expect(subject.matches?('*.orders.sync.warehouse')).to be true
    end

    it 'matches greedy wildcard' do
      expect(subject.matches?('production.>')).to be true
      expect(subject.matches?('production.orders.>')).to be true
    end

    it 'does not match different subject' do
      expect(subject.matches?('staging.orders.sync.warehouse')).to be false
      expect(subject.matches?('production.users.sync.warehouse')).to be false
    end

    it 'does not match partial subject' do
      expect(subject.matches?('production.orders')).to be false
    end

    it 'works with Subject objects' do
      pattern = described_class.new('production.*.sync.*')
      expect(subject.matches?(pattern)).to be true
    end
  end

  describe '#==' do
    it 'returns true for subjects with same value' do
      subject1 = described_class.new('dev.app1.sync.app2')
      subject2 = described_class.new('dev.app1.sync.app2')

      expect(subject1).to eq(subject2)
    end

    it 'returns false for subjects with different values' do
      subject1 = described_class.new('dev.app1.sync.app2')
      subject2 = described_class.new('prod.app1.sync.app2')

      expect(subject1).not_to eq(subject2)
    end

    it 'can be used as hash key' do
      subject1 = described_class.new('dev.app.sync.dest')
      subject2 = described_class.new('dev.app.sync.dest')

      hash = { subject1 => 'value1' }
      expect(hash[subject2]).to eq('value1')
    end
  end

  describe '#to_s' do
    it 'returns the subject string' do
      subject = described_class.new('test.subject.value')

      expect(subject.to_s).to eq('test.subject.value')
    end

    it 'can be used in string interpolation' do
      subject = described_class.new('production.orders.sync.warehouse')

      message = "Publishing to #{subject}"
      expect(message).to eq('Publishing to production.orders.sync.warehouse')
    end
  end

  describe 'immutability' do
    it 'freezes the subject instance' do
      subject = described_class.new('dev.app.sync.dest')

      expect(subject).to be_frozen
    end

    it 'prevents modification' do
      subject = described_class.new('dev.app.sync.dest')

      expect do
        subject.instance_variable_set(:@value, 'modified')
      end.to raise_error(FrozenError)
    end
  end

  describe 'edge cases' do
    it 'handles single token subject' do
      subject = described_class.new('simple')

      expect(subject.to_s).to eq('simple')
    end

    it 'handles subject with many tokens' do
      long_subject = 'a.b.c.d.e.f.g.h.i.j'
      subject = described_class.new(long_subject)

      expect(subject.to_s).to eq(long_subject)
    end

    it 'preserves dashes and underscores' do
      subject = described_class.new('env-staging.user_service.sync.email-service')

      expect(subject.to_s).to eq('env-staging.user_service.sync.email-service')
    end
  end
end
