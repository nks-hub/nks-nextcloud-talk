CREATE TABLE registrations (
    device_identifier text PRIMARY KEY,
    device_signature text NOT NULL,
    public_key_pem text NOT NULL,
    public_key_der bytea NOT NULL,
    public_key_fingerprint bytea NOT NULL,
    token_hash text NOT NULL,
    encrypted_token bytea NOT NULL,
    token_nonce bytea NOT NULL,
    generation bigint NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT registrations_device_identifier_length CHECK (length(device_identifier) = 88),
    CONSTRAINT registrations_device_signature_length CHECK (length(device_signature) = 344),
    CONSTRAINT registrations_public_key_pem_length CHECK (length(public_key_pem) BETWEEN 450 AND 8192),
    CONSTRAINT registrations_public_key_der_length CHECK (octet_length(public_key_der) BETWEEN 256 AND 1024),
    CONSTRAINT registrations_public_key_fingerprint_length CHECK (octet_length(public_key_fingerprint) = 32),
    CONSTRAINT registrations_token_hash_shape CHECK (token_hash ~ '^[a-f0-9]{128}$'),
    CONSTRAINT registrations_encrypted_token_length CHECK (octet_length(encrypted_token) BETWEEN 17 AND 4112),
    CONSTRAINT registrations_token_nonce_length CHECK (octet_length(token_nonce) = 12),
    CONSTRAINT registrations_generation_positive CHECK (generation > 0)
);

CREATE INDEX registrations_active_token_hash_idx
    ON registrations (token_hash)
    WHERE revoked_at IS NULL;

CREATE TABLE delivery_jobs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_identifier text NOT NULL REFERENCES registrations (device_identifier),
    registration_generation bigint NOT NULL,
    envelope_digest bytea NOT NULL,
    subject text NOT NULL,
    signature text NOT NULL,
    priority text NOT NULL,
    notification_type text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    attempt_count integer NOT NULL DEFAULT 0,
    available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_id text,
    lease_until timestamptz,
    last_error_class text,
    delivered_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT delivery_jobs_generation_positive CHECK (registration_generation > 0),
    CONSTRAINT delivery_jobs_digest_length CHECK (octet_length(envelope_digest) = 32),
    CONSTRAINT delivery_jobs_subject_length CHECK (length(subject) = 344),
    CONSTRAINT delivery_jobs_signature_length CHECK (length(signature) = 344),
    CONSTRAINT delivery_jobs_priority CHECK (priority IN ('high', 'normal')),
    CONSTRAINT delivery_jobs_notification_type CHECK (notification_type IN ('alert', 'voip', 'background')),
    CONSTRAINT delivery_jobs_status CHECK (status IN ('pending', 'leased', 'delivered', 'permanent_failure', 'cancelled')),
    CONSTRAINT delivery_jobs_attempt_nonnegative CHECK (attempt_count >= 0),
    CONSTRAINT delivery_jobs_lease_shape CHECK (
        (status = 'leased' AND lease_id IS NOT NULL AND lease_until IS NOT NULL)
        OR
        (status <> 'leased' AND lease_id IS NULL AND lease_until IS NULL)
    ),
    CONSTRAINT delivery_jobs_error_class_shape CHECK (
        last_error_class IS NULL OR last_error_class ~ '^[a-z][a-z0-9_]{0,63}$'
    ),
    CONSTRAINT delivery_jobs_delivered_shape CHECK (
        (status = 'delivered' AND delivered_at IS NOT NULL)
        OR
        (status <> 'delivered' AND delivered_at IS NULL)
    ),
    UNIQUE (device_identifier, envelope_digest)
);

CREATE INDEX delivery_jobs_claim_idx
    ON delivery_jobs (available_at, created_at, id)
    WHERE status = 'pending';

CREATE INDEX delivery_jobs_lease_idx
    ON delivery_jobs (lease_until)
    WHERE status = 'leased';

CREATE INDEX delivery_jobs_cleanup_idx
    ON delivery_jobs (updated_at)
    WHERE status IN ('delivered', 'permanent_failure', 'cancelled');
