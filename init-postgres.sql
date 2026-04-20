-- ==================================================
-- MusicTwins: PostgreSQL - Inicialización
-- Core de la app: usuarios, amigos, actividad, chat
-- ==================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ==================================================
-- TABLAS
-- ==================================================

-- Usuarios autenticados via Spotify OAuth
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  spotify_id TEXT UNIQUE NOT NULL,
  display_name TEXT NOT NULL,
  email TEXT,
  avatar_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Tokens de streaming (cifrados con pgcrypto)
CREATE TABLE IF NOT EXISTS streaming_accounts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL DEFAULT 'spotify',
  provider_user_id TEXT NOT NULL,
  access_token_encrypted TEXT NOT NULL,
  refresh_token_encrypted TEXT NOT NULL,
  access_token_expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT unique_user_provider UNIQUE(user_id, provider)
);

-- Relaciones de amistad (unidireccionales, lógica simétrica en app)
CREATE TABLE IF NOT EXISTS friends (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  friend_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'PENDING',
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT no_self_friend CHECK (user_id != friend_user_id),
  CONSTRAINT unique_friendship UNIQUE(user_id, friend_user_id),
  CONSTRAINT valid_status CHECK (status IN ('PENDING', 'ACCEPTED', 'REJECTED'))
);

-- Eventos de reproducción (feed social)
CREATE TABLE IF NOT EXISTS playback_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL DEFAULT 'spotify',
  track_id TEXT NOT NULL,
  track_name TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  album_name TEXT,
  album_image_url TEXT,
  raw_metadata JSONB,
  played_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Reacciones con emoji a reproducciones
CREATE TABLE IF NOT EXISTS reactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  playback_event_id UUID NOT NULL REFERENCES playback_events(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT unique_reaction UNIQUE(user_id, playback_event_id, emoji)
);

-- Notas/comentarios cortos sobre reproducciones
CREATE TABLE IF NOT EXISTS notes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  playback_event_id UUID NOT NULL REFERENCES playback_events(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT content_max_280 CHECK (LENGTH(content) BETWEEN 1 AND 280)
);

-- Conversaciones 1:1 (mensajes en MongoDB)
CREATE TABLE IF NOT EXISTS conversations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user1_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user2_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  origin_playback_event_id UUID REFERENCES playback_events(id) ON DELETE SET NULL,
  last_message_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT no_self_conv CHECK (user1_id != user2_id),
  CONSTRAINT unique_conversation UNIQUE(user1_id, user2_id)
);

-- ==================================================
-- TRIGGER: updated_at automático
-- ==================================================

CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_upd BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER trg_streaming_upd BEFORE UPDATE ON streaming_accounts FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER trg_friends_upd BEFORE UPDATE ON friends FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER trg_conversations_upd BEFORE UPDATE ON conversations FOR EACH ROW EXECUTE FUNCTION update_timestamp();

-- ==================================================
-- ÍNDICES ESENCIALES
-- ==================================================

-- Feed: actividad por usuario, orden cronológico
CREATE INDEX IF NOT EXISTS idx_playback_user_date ON playback_events(user_id, played_at DESC);

-- Amigos: filtrar por estado
CREATE INDEX IF NOT EXISTS idx_friends_status ON friends(user_id, status);

-- Reacciones y notas: buscar por evento del feed
CREATE INDEX IF NOT EXISTS idx_reactions_event ON reactions(playback_event_id);
CREATE INDEX IF NOT EXISTS idx_notes_event ON notes(playback_event_id);

-- Conversaciones: buscar por participante
CREATE INDEX IF NOT EXISTS idx_conv_user1 ON conversations(user1_id);
CREATE INDEX IF NOT EXISTS idx_conv_user2 ON conversations(user2_id);

-- ==================================================
-- CIFRADO: Funciones para tokens de Spotify
-- ==================================================

CREATE OR REPLACE FUNCTION encrypt_token(token TEXT, secret TEXT)
RETURNS TEXT AS $$
BEGIN
  RETURN encode(pgp_sym_encrypt(token, secret, 'cipher-algo=aes256'), 'base64');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION decrypt_token(encrypted_token TEXT, secret TEXT)
RETURNS TEXT AS $$
BEGIN
  RETURN pgp_sym_decrypt(decode(encrypted_token, 'base64'), secret);
END;
$$ LANGUAGE plpgsql;

-- ==================================================
-- ROLES: creados por init-postgres-roles.sh (lee de env vars)
-- No poner credenciales aquí, se exponen en git.
-- ==================================================
