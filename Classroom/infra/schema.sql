CREATE TABLE IF NOT EXISTS courses (
  id UUID PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS live_rooms (
  id UUID PRIMARY KEY,
  course_id UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  share_code TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('scheduled', 'live', 'ended')),
  heat_base INTEGER NOT NULL DEFAULT 86 CHECK (heat_base >= 0),
  heat_multiplier NUMERIC(5,2) NOT NULL DEFAULT 1.00 CHECK (heat_multiplier >= 0),
  allow_chat BOOLEAN NOT NULL DEFAULT TRUE,
  allow_hand_raise BOOLEAN NOT NULL DEFAULT TRUE,
  allow_cohost BOOLEAN NOT NULL DEFAULT TRUE,
  local_recording BOOLEAN NOT NULL DEFAULT TRUE,
  resolution TEXT NOT NULL DEFAULT '720p' CHECK (resolution IN ('540p', '720p', '1080p')),
  started_at TIMESTAMPTZ,
  ended_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS participants (
  id UUID PRIMARY KEY,
  room_id UUID NOT NULL REFERENCES live_rooms(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  nickname TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('teacher', 'viewer', 'cohost')),
  state TEXT NOT NULL CHECK (state IN ('connected', 'left', 'kicked')),
  muted BOOLEAN NOT NULL DEFAULT FALSE,
  hand_raised_at TIMESTAMPTZ,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (room_id, device_id)
);

CREATE TABLE IF NOT EXISTS chat_messages (
  id UUID PRIMARY KEY,
  room_id UUID NOT NULL REFERENCES live_rooms(id) ON DELETE CASCADE,
  participant_id UUID NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  body TEXT NOT NULL CHECK (char_length(body) BETWEEN 1 AND 500),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS replays (
  id UUID PRIMARY KEY,
  room_id UUID NOT NULL REFERENCES live_rooms(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'uploading', 'ready', 'failed')),
  playback_url TEXT,
  duration_seconds INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS orders (
  id UUID PRIMARY KEY,
  course_id UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('wechat', 'alipay')),
  status TEXT NOT NULL CHECK (status IN ('pending', 'paid', 'cancelled', 'refunded')),
  amount_fen INTEGER NOT NULL CHECK (amount_fen >= 0),
  provider_reference TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS access_grants (
  id UUID PRIMARY KEY,
  course_id UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  order_id UUID REFERENCES orders(id) ON DELETE SET NULL,
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (course_id, device_id)
);

CREATE INDEX IF NOT EXISTS participants_room_state_idx ON participants(room_id, state);
CREATE INDEX IF NOT EXISTS chat_messages_room_created_idx ON chat_messages(room_id, created_at);
CREATE INDEX IF NOT EXISTS orders_course_device_idx ON orders(course_id, device_id);
