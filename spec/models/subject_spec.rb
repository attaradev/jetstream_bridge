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

  describe '#env' do
    it 'returns first token as environment' do
      subject = described_class.new('production.app.sync.dest')
      expect(subject.env).to eq('production')
    end

    it 'returns nil when no tokens exist' do
      # Single token without separator
      subject = described_class.new('production')
      expect(subject.env).to eq('production')
    end
  end

  describe '#source_app' do
    it 'returns second token as source app' do
      subject = described_class.new('production.orders.sync.warehouse')
      expect(subject.source_app).to eq('orders')
    end

    it 'returns app name for DLQ subjects' do
      dlq_subject = described_class.dlq(env: 'production', app_name: 'api')
      expect(dlq_subject.source_app).to eq('api')
    end

    it 'returns nil when second token does not exist' do
      subject = described_class.new('production')
      expect(subject.source_app).to be_nil
    end
  end

  describe '#dest_app' do
    it 'returns fourth token as destination app' do
      subject = described_class.new('production.orders.sync.warehouse')
      expect(subject.dest_app).to eq('warehouse')
    end

    it 'returns nil when fourth token does not exist' do
      subject = described_class.new('production.orders.sync')
      expect(subject.dest_app).to be_nil
    end
  end

  describe '#dlq?' do
    it 'returns true for DLQ subjects' do
      subject = described_class.dlq(env: 'production', app_name: 'api')
      expect(subject.dlq?).to be true
    end

    it 'returns false for regular subjects' do
      subject = described_class.new('production.orders.sync.warehouse')
      expect(subject.dlq?).to be false
    end

    it 'returns false when second token is not sync' do
      subject = described_class.new('production.orders.other.dlq')
      expect(subject.dlq?).to be false
    end

    it 'returns false when third token is not dlq' do
      subject = described_class.new('production.sync.other')
      expect(subject.dlq?).to be false
    end

    it 'returns false for short subjects' do
      subject = described_class.new('production.sync')
      expect(subject.dlq?).to be false
    end
  end

  describe '.dlq' do
    it 'creates a DLQ subject with app name' do
      subject = described_class.dlq(env: 'production', app_name: 'api')
      expect(subject.to_s).to eq('production.api.sync.dlq')
      expect(subject.dlq?).to be true
    end

    it 'creates DLQ subject for different environments' do
      subject = described_class.dlq(env: 'staging', app_name: 'worker')
      expect(subject.to_s).to eq('staging.worker.sync.dlq')
    end
  end

  describe '.validate_component!' do
    it 'accepts valid component' do
      expect(described_class.validate_component!('valid_name', 'app_name')).to be true
    end

    it 'rejects component with dot separator' do
      expect do
        described_class.validate_component!('invalid.name', 'app_name')
      end.to raise_error(ArgumentError, /cannot contain NATS wildcards/)
    end

    it 'rejects component with single wildcard' do
      expect do
        described_class.validate_component!('invalid*name', 'app_name')
      end.to raise_error(ArgumentError, /cannot contain NATS wildcards/)
    end

    it 'rejects component with multi wildcard' do
      expect do
        described_class.validate_component!('invalid>name', 'app_name')
      end.to raise_error(ArgumentError, /cannot contain NATS wildcards/)
    end

    it 'rejects empty component' do
      expect do
        described_class.validate_component!('', 'app_name')
      end.to raise_error(ArgumentError, /cannot be empty/)
    end

    it 'rejects component with only whitespace' do
      expect do
        described_class.validate_component!('   ', 'app_name')
      end.to raise_error(ArgumentError, /cannot be empty/)
    end

    it 'converts non-string values to string' do
      expect(described_class.validate_component!(123, 'id')).to be true
    end
  end

  describe 'validation in initialize' do
    it 'rejects subject with only separators' do
      expect do
        described_class.new('...')
      end.to raise_error(ArgumentError, /only separators/)
    end

    it 'rejects subject with spaces' do
      expect do
        described_class.new('invalid subject')
      end.to raise_error(ArgumentError, /invalid format/)
    end

    it 'rejects subject with tabs' do
      expect do
        described_class.new("invalid\tsubject")
      end.to raise_error(ArgumentError, /invalid format/)
    end

    it 'rejects subject with newlines' do
      expect do
        described_class.new("invalid\nsubject")
      end.to raise_error(ArgumentError, /invalid format/)
    end
  end

  describe '#eql?' do
    it 'is an alias for ==' do
      subject1 = described_class.new('dev.app.sync.dest')
      subject2 = described_class.new('dev.app.sync.dest')

      expect(subject1.eql?(subject2)).to be true
    end
  end

  describe '#hash' do
    it 'returns consistent hash for same value' do
      subject1 = described_class.new('dev.app.sync.dest')
      subject2 = described_class.new('dev.app.sync.dest')

      expect(subject1.hash).to eq(subject2.hash)
    end

    it 'returns different hash for different values' do
      subject1 = described_class.new('dev.app.sync.dest')
      subject2 = described_class.new('prod.app.sync.dest')

      expect(subject1.hash).not_to eq(subject2.hash)
    end
  end
end
