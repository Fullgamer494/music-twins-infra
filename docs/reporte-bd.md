# MusicTwins — Reporte de Arquitectura de Base de Datos

## 1. Visión General

MusicTwins utiliza una arquitectura **polyglot** con dos motores de base de datos, cada uno seleccionado por sus fortalezas para el tipo de dato que maneja:

| Motor | Rol | Justificación |
|-------|-----|---------------|
| **PostgreSQL 14** | Core de la aplicación | Integridad referencial, transacciones ACID, cifrado de tokens |
| **MongoDB 6** | Mensajería en tiempo real | Flexibilidad de esquema, escrituras rápidas, escalabilidad horizontal |

```
┌─────────────────────────────────────────────────────┐
│                   POSTGRESQL (core)                 │
│  users · streaming_accounts · friends               │
│  playback_events · reactions · notes · conversations│
└──────────────────────┬──────────────────────────────┘
                       │ conversation_id (UUID)
              ┌────────▼────────┐
              │  MONGODB (chat) │
              │    messages     │
              └─────────────────┘
```

La relación entre ambos motores se da a través del campo `conversation_id` en MongoDB, que almacena el UUID de la tabla `conversations` de PostgreSQL como string.

---

## 2. Entidades en PostgreSQL

### 2.1 `users`
Almacena el perfil de cada usuario autenticado. Es la tabla central del sistema, ya que todas las demás entidades dependen de ella.

| Campo | Tipo | Propósito |
|-------|------|-----------|
| `id` | UUID PK | Identificador único |
| `spotify_id` | TEXT UNIQUE | ID de Spotify, usado en el callback OAuth para identificar al usuario |
| `display_name` | TEXT | Nombre visible en el feed y lista de amigos |
| `email` | TEXT nullable | Correo obtenido de Spotify (opcional, no todos lo comparten) |
| `avatar_url` | TEXT nullable | Foto de perfil de Spotify |
| `created_at`, `updated_at` | TIMESTAMPTZ | Auditoría temporal |

**Justificación:** Sin esta tabla no hay forma de vincular actividad musical, amistades ni mensajes a un usuario concreto. `spotify_id` como UNIQUE permite evitar duplicados en el flujo OAuth.

---

### 2.2 `streaming_accounts`
Guarda los tokens OAuth de Spotify **cifrados** (AES-256 vía pgcrypto). Separada de `users` para permitir futuros providers (Apple Music en Fase 2).

| Campo | Tipo | Propósito |
|-------|------|-----------|
| `user_id` | UUID FK → users | Dueño de la cuenta |
| `provider` | TEXT | Proveedor (`spotify`, preparado para `apple_music`) |
| `provider_user_id` | TEXT | ID del usuario en el proveedor |
| `access_token_encrypted` | TEXT | Token de acceso cifrado |
| `refresh_token_encrypted` | TEXT | Token de refresh cifrado |
| `access_token_expires_at` | TIMESTAMPTZ | Cuándo expira el access token |

**Justificación:** Los tokens se cifran en BD para cumplir RNF-04 (nunca exponer tokens al frontend). La separación por `provider` permite vincular múltiples servicios de streaming al mismo usuario sin modificar la tabla.

**Constraint:** `UNIQUE(user_id, provider)` — un usuario solo tiene una cuenta por proveedor.

---

### 2.3 `friends`
Modela el grafo social. Las solicitudes son unidireccionales: `user_id` envía la solicitud a `friend_user_id`.

| Campo | Tipo | Propósito |
|-------|------|-----------|
| `user_id` | UUID FK → users | Quien envía la solicitud |
| `friend_user_id` | UUID FK → users | Quien la recibe |
| `status` | TEXT | Estado: `PENDING`, `ACCEPTED`, `REJECTED` |

**Justificación:** El feed solo muestra actividad de amigos con `status = 'ACCEPTED'`. La tabla permite implementar RF-11 (enviar solicitud), RF-12 (aceptar/rechazar) y RF-14 (evitar duplicados).

**Constraints:**
- `UNIQUE(user_id, friend_user_id)` — impide solicitudes duplicadas
- `CHECK(user_id != friend_user_id)` — impide auto-amistad
- `CHECK(status IN ('PENDING','ACCEPTED','REJECTED'))` — estados válidos

---

### 2.4 `playback_events`
Registro histórico de las canciones que los usuarios han escuchado. Es la tabla que alimenta el **feed social**.

| Campo | Tipo | Propósito |
|-------|------|-----------|
| `user_id` | UUID FK → users | Quién escuchó |
| `track_id` | TEXT | ID del track en Spotify |
| `track_name`, `artist_name` | TEXT | Datos de la canción para renderizar en el feed |
| `album_name`, `album_image_url` | TEXT nullable | Carátula del álbum |
| `raw_metadata` | JSONB | Payload completo de Spotify (futura flexibilidad) |
| `played_at` | TIMESTAMPTZ | Cuándo se reprodujo |

**Justificación:** Es la pieza central del feed (RF-15). Al persisitir los eventos, el feed no depende de llamadas en tiempo real a Spotify. El campo `raw_metadata` como JSONB permite guardar datos extra de Spotify sin alterar el esquema.

**Índice clave:** `(user_id, played_at DESC)` — construir el feed ordenado cronológicamente por usuario.

---

### 2.5 `reactions`
Emojis que los usuarios colocan en los eventos del feed de sus amigos.

| Campo | Tipo | Propósito |
|-------|------|-----------|
| `user_id` | UUID FK → users | Quién reacciona |
| `playback_event_id` | UUID FK → playback_events | A qué evento |
| `emoji` | TEXT | Emoji seleccionado |

**Justificación:** Implementa RF-19 (reaccionar con emojis) y RF-22 (conteos agrupados por tipo). La constraint `UNIQUE(user_id, playback_event_id, emoji)` evita reacciones duplicadas del mismo tipo por el mismo usuario (RF-20).

---

### 2.6 `notes`
Comentarios cortos (máximo 280 caracteres) que los usuarios escriben sobre una reproducción.

| Campo | Tipo | Propósito |
|-------|------|-----------|
| `user_id` | UUID FK → users | Autor de la nota |
| `playback_event_id` | UUID FK → playback_events | Evento comentado |
| `content` | TEXT (max 280) | Texto de la nota |

**Justificación:** Implementa RF-21. El límite de 280 caracteres se aplica a nivel de BD con `CHECK(LENGTH(content) BETWEEN 1 AND 280)`, garantizando integridad sin depender del frontend.

---

### 2.7 `conversations`
Metadatos de conversaciones 1:1 entre amigos. Los mensajes se almacenan en MongoDB.

| Campo | Tipo | Propósito |
|-------|------|-----------|
| `user1_id`, `user2_id` | UUID FK → users | Participantes |
| `origin_playback_event_id` | UUID FK nullable → playback_events | Canción que originó el chat (si aplica) |
| `last_message_at` | TIMESTAMPTZ nullable | Timestamp del último mensaje (para ordenar lista) |

**Justificación:** Cubre dos flujos: conversación general (RF-24, `origin = NULL`) y conversación contextual desde el feed (RF-25, `origin = UUID del evento`). Al vivir en PostgreSQL mantiene la integridad referencial con `users` y `playback_events`.

**Constraint:** `UNIQUE(user1_id, user2_id)` — solo una conversación por par de usuarios.

---

## 3. Entidad en MongoDB

### 3.1 `messages`
Mensajes de texto dentro de una conversación. Se eligió MongoDB por su rendimiento en escrituras frecuentes y su facilidad para consultas paginadas.

| Campo | Tipo | Propósito |
|-------|------|-----------|
| `conversation_id` | String (UUID) | Referencia a `conversations.id` en PostgreSQL |
| `sender_id` | String (UUID) | Quién envía |
| `receiver_id` | String (UUID) | Quién recibe |
| `content` | String (1-5000 chars) | Cuerpo del mensaje |
| `playback_event_id` | String nullable | Referencia opcional a canción |
| `read` | Boolean | Si fue leído por el receptor |
| `read_at` | Date nullable | Cuándo fue leído |
| `created_at` | Date | Timestamp de envío |

**Justificación:** Implementa RF-26 (mensajes en tiempo real), RF-27 (historial), RF-29 (mensajes sin contexto de canción) y RF-30 (leído/no leído). MongoDB fue elegido porque:
- El volumen de mensajes crece mucho más rápido que las demás entidades
- Las consultas son simples (por conversación + orden cronológico)
- No requiere JOINs complejos con otras tablas

**Validación:** JSON Schema en MongoDB rechaza documentos que no cumplan el formato UUID y los campos requeridos.

**Índices:**
- `(conversation_id, created_at DESC)` — cargar historial paginado
- `(receiver_id, read)` — contar no leídos por usuario

---

## 4. Diagrama ER

![Diagrama Entidad-Relación de MusicTwins](diagrama_er.png)

---

## 5. Estructura de Archivos

```
music-twins-infra/
├── scripts/                          # Archivos ejecutables
│   ├── init-postgres.sql             # Esquema PostgreSQL (7 tablas)
│   ├── init-mongodb.js               # Esquema MongoDB (1 colección)
│   ├── docker-compose.yml            # Levantar PostgreSQL + MongoDB
│   ├── env.example                   # Variables de entorno
│   ├── setup-databases.sh            # Setup automático completo
│   └── backup-restore.sh            # Respaldo y restauración
│
└── docs/                             # Documentación
    ├── reporte-bd.md                 # Este reporte
    ├── diagrama_er.png               # Diagrama ER
    └── MusicTwins – Doc. Técnico.pdf # Documento técnico del proyecto
```

---

## 6. Seguridad Implementada

| Mecanismo | Implementación |
|-----------|----------------|
| Cifrado de tokens | pgcrypto AES-256 (`encrypt_token`, `decrypt_token`) |
| Roles diferenciados | `musictwins_app` (read/write), `musictwins_readonly` (solo lectura) |
| Constraints de integridad | FK con CASCADE, UNIQUEs, CHECKs de longitud y formato |
| Validación en MongoDB | JSON Schema que rechaza documentos inválidos |
| Variables de entorno | Zero hardcoding de credenciales en archivos de configuración |

---

## 7. Inicio Rápido

```bash
# 1. Copiar variables de entorno
cp scripts/env.example scripts/.env.local

# 2. Levantar servicios
cd scripts && docker-compose --env-file .env.local up -d

# 3. O usar el script automático
chmod +x scripts/setup-databases.sh
./scripts/setup-databases.sh local
```

**Cadenas de conexión para la app Next.js:**
```env
DATABASE_URL=postgresql://musictwins_app:devpass123@localhost:5432/musictwins
MONGO_URI=mongodb://musictwins_app:mongopass123@localhost:27017/musictwins?authSource=musictwins
```
