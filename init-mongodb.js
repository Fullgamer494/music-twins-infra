// ==================================================
// MusicTwins: MongoDB - Inicialización
// Solo mensajería (conversations vive en PostgreSQL)
// ==================================================

const DB_NAME = process.env.MONGO_DB_NAME || 'musictwins';
const APP_USER = process.env.MONGO_USER || 'musictwins_app';
const APP_PASSWORD = process.env.MONGO_PASSWORD || 'mongopass123';

db = db.getSiblingDB(DB_NAME);

print(`[init] Base de datos: ${DB_NAME}`);

// ==================================================
// COLECCIÓN: messages
// ==================================================

db.createCollection('messages', {
  validator: {
    $jsonSchema: {
      bsonType: 'object',
      required: ['conversation_id', 'sender_id', 'receiver_id', 'content', 'created_at'],
      properties: {
        conversation_id: {
          bsonType: 'string',
          pattern: '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          description: 'UUID de conversations en PostgreSQL'
        },
        sender_id: {
          bsonType: 'string',
          pattern: '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        },
        receiver_id: {
          bsonType: 'string',
          pattern: '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        },
        content: {
          bsonType: 'string',
          minLength: 1,
          maxLength: 5000
        },
        playback_event_id: {
          bsonType: ['string', 'null'],
          description: 'Referencia opcional a canción del feed'
        },
        read: { bsonType: 'bool' },
        read_at: { bsonType: ['date', 'null'] },
        created_at: { bsonType: 'date' }
      }
    }
  }
});

// ==================================================
// ÍNDICES ESENCIALES
// ==================================================

// Historial de mensajes por conversación (paginado)
db.messages.createIndex(
  { conversation_id: 1, created_at: -1 },
  { name: 'idx_msg_history' }
);

// Contar mensajes no leídos por receptor
db.messages.createIndex(
  { receiver_id: 1, read: 1 },
  { name: 'idx_msg_unread' }
);

// ==================================================
// USUARIO DE LA APP
// ==================================================

try { db.dropUser(APP_USER); } catch (e) { /* no existía */ }

db.createUser({
  user: APP_USER,
  pwd: APP_PASSWORD,
  roles: [{ role: 'readWrite', db: DB_NAME }]
});

print(`[init] ✅ MongoDB listo - colección: messages, usuario: ${APP_USER}`);
