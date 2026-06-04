-- ══════════════════════════════════════════════════════════════════
-- BASE DE DATOS: EL INTERMEDIO — Casino App
-- Motor: PostgreSQL 15+ (compatible con MySQL 8+ con ajustes menores)
-- ══════════════════════════════════════════════════════════════════

-- ── EXTENSIONES ────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid(), crypt()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- búsqueda fuzzy de alias/nombres

-- ══════════════════════════════════════════════════════════════════
-- 1. USUARIOS
-- ══════════════════════════════════════════════════════════════════

CREATE TABLE usuarios (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    username        VARCHAR(40)     NOT NULL UNIQUE,
    password_hash   VARCHAR(255)    NOT NULL,            -- bcrypt/crypt
    nombre          VARCHAR(120)    NOT NULL,
    alias           VARCHAR(30)     NOT NULL UNIQUE,
    cbu             VARCHAR(22),                         -- CBU/CVU Argentina
    telefono        VARCHAR(30),
    provincia       VARCHAR(80),
    localidad       VARCHAR(80),
    -- Avatar
    avatar_type     VARCHAR(10)     NOT NULL DEFAULT 'emoji'
                        CHECK (avatar_type IN ('emoji','initials','photo')),
    avatar_emoji    VARCHAR(10)     DEFAULT '🎭',
    avatar_iniciales VARCHAR(4),
    avatar_color_idx SMALLINT       DEFAULT 0,
    avatar_photo_url TEXT,                               -- URL o Base64 si se guarda en S3
    -- Saldo
    saldo           NUMERIC(14,2)   NOT NULL DEFAULT 0
                        CHECK (saldo >= 0),
    -- Estadísticas de vida
    total_depositado  NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_retirado    NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_manos       INTEGER       NOT NULL DEFAULT 0,
    -- Control
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,
    creado_en       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    ultimo_acceso   TIMESTAMPTZ
);

CREATE INDEX idx_usuarios_alias    ON usuarios (LOWER(alias));
CREATE INDEX idx_usuarios_username ON usuarios (LOWER(username));


-- ══════════════════════════════════════════════════════════════════
-- 2. SESIONES
-- ══════════════════════════════════════════════════════════════════

CREATE TABLE sesiones (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id      UUID            NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    token           VARCHAR(128)    NOT NULL UNIQUE,    -- JWT o token opaco
    ip              INET,
    user_agent      TEXT,
    creada_en       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    expira_en       TIMESTAMPTZ     NOT NULL DEFAULT NOW() + INTERVAL '30 days',
    activa          BOOLEAN         NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_sesiones_usuario ON sesiones (usuario_id);
CREATE INDEX idx_sesiones_token   ON sesiones (token);


-- ══════════════════════════════════════════════════════════════════
-- 3. MESAS
-- ══════════════════════════════════════════════════════════════════

CREATE TYPE mesa_estado    AS ENUM ('open','filling','playing','full','closed');
CREATE TYPE mesa_categoria AS ENUM ('small','mid','big');

CREATE TABLE mesas (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          VARCHAR(60)     NOT NULL,
    categoria       mesa_categoria  NOT NULL DEFAULT 'mid',
    buy_in          NUMERIC(14,2)   NOT NULL CHECK (buy_in > 0),
    max_asientos    SMALLINT        NOT NULL CHECK (max_asientos BETWEEN 1 AND 10),
    estado          mesa_estado     NOT NULL DEFAULT 'open',
    pozo            NUMERIC(14,2)   NOT NULL DEFAULT 0 CHECK (pozo >= 0),
    manos_jugadas   INTEGER         NOT NULL DEFAULT 0,
    urgency_timer   INTEGER,                            -- segundos restantes (filling)
    -- Timestamps
    creada_en       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    ultima_actividad TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    cerrada_en      TIMESTAMPTZ
);

CREATE INDEX idx_mesas_estado    ON mesas (estado);
CREATE INDEX idx_mesas_categoria ON mesas (categoria);


-- ══════════════════════════════════════════════════════════════════
-- 4. JUGADORES EN MESA (asientos)
-- ══════════════════════════════════════════════════════════════════

CREATE TYPE asiento_tipo AS ENUM ('humano','bot','espectador');

CREATE TABLE mesa_asientos (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    mesa_id         UUID            NOT NULL REFERENCES mesas(id) ON DELETE CASCADE,
    usuario_id      UUID            REFERENCES usuarios(id) ON DELETE SET NULL,  -- NULL = bot
    -- Datos denormalizados para bots (no tienen registro en usuarios)
    nombre_display  VARCHAR(60)     NOT NULL,
    emoji           VARCHAR(10)     DEFAULT '⭐',
    color_hex       VARCHAR(7)      DEFAULT '#c9a84c',
    tipo            asiento_tipo    NOT NULL DEFAULT 'humano',
    -- Estado en mesa
    saldo_en_mesa   NUMERIC(14,2)   NOT NULL DEFAULT 0,
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,
    unido_en        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    salio_en        TIMESTAMPTZ,
    UNIQUE (mesa_id, usuario_id)    -- un humano, un asiento por mesa
);

CREATE INDEX idx_asientos_mesa    ON mesa_asientos (mesa_id);
CREATE INDEX idx_asientos_usuario ON mesa_asientos (usuario_id);


-- ══════════════════════════════════════════════════════════════════
-- 5. MANOS (rondas de juego)
-- ══════════════════════════════════════════════════════════════════

CREATE TYPE carta_palo AS ENUM ('o','e','c','b');  -- oros,espadas,copas,bastos
CREATE TYPE carta_valor AS ENUM ('A','2','3','4','5','6','7','J','Q','K');

CREATE TABLE manos (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    mesa_id         UUID            NOT NULL REFERENCES mesas(id) ON DELETE CASCADE,
    numero_mano     INTEGER         NOT NULL,            -- secuencial por mesa
    -- Cartas de la mano
    carta1_palo     carta_palo,
    carta1_valor    carta_valor,
    carta2_palo     carta_palo,
    carta2_valor    carta_valor,
    carta_media_palo  carta_palo,
    carta_media_valor carta_valor,
    -- Rango calculado
    rango_lo        SMALLINT,                           -- valor numérico de la carta baja
    rango_hi        SMALLINT,                           -- valor numérico de la carta alta
    spread          SMALLINT,                           -- cartas intermedias posibles
    -- Pozo al inicio de la mano
    pozo_inicio     NUMERIC(14,2)   NOT NULL DEFAULT 0,
    pozo_final      NUMERIC(14,2),
    -- Ganador
    ganador_nombre  VARCHAR(60),
    ganador_tipo    asiento_tipo,
    -- Timestamps
    iniciada_en     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    finalizada_en   TIMESTAMPTZ,
    UNIQUE (mesa_id, numero_mano)
);

CREATE INDEX idx_manos_mesa ON manos (mesa_id);


-- ══════════════════════════════════════════════════════════════════
-- 6. APUESTAS (una por jugador por mano)
-- ══════════════════════════════════════════════════════════════════

CREATE TYPE resultado_apuesta AS ENUM ('win','lose','tie','pass');

CREATE TABLE apuestas (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    mano_id         UUID            NOT NULL REFERENCES manos(id) ON DELETE CASCADE,
    asiento_id      UUID            NOT NULL REFERENCES mesa_asientos(id) ON DELETE CASCADE,
    usuario_id      UUID            REFERENCES usuarios(id) ON DELETE SET NULL,
    es_bot          BOOLEAN         NOT NULL DEFAULT FALSE,
    -- Cartas propias del jugador (para bots/espectador)
    carta1_palo     carta_palo,
    carta1_valor    carta_valor,
    carta2_palo     carta_palo,
    carta2_valor    carta_valor,
    carta_media_palo  carta_palo,
    carta_media_valor carta_valor,
    -- Apuesta
    monto_apostado  NUMERIC(14,2)   NOT NULL DEFAULT 0 CHECK (monto_apostado >= 0),
    resultado       resultado_apuesta NOT NULL,
    ganancia_neta   NUMERIC(14,2),                      -- positivo = ganó, negativo = perdió
    saldo_antes     NUMERIC(14,2),
    saldo_despues   NUMERIC(14,2),
    -- Tiempo
    apostado_en     TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_apuestas_mano    ON apuestas (mano_id);
CREATE INDEX idx_apuestas_usuario ON apuestas (usuario_id);
CREATE INDEX idx_apuestas_fecha   ON apuestas (apostado_en);


-- ══════════════════════════════════════════════════════════════════
-- 7. MOVIMIENTOS DE BILLETERA
-- ══════════════════════════════════════════════════════════════════

CREATE TYPE movimiento_tipo AS ENUM (
    'deposito',         -- recarga del jugador
    'retiro',           -- retiro a CBU
    'apuesta',          -- dinero apostado
    'ganancia',         -- dinero ganado
    'entrada_mesa',     -- buy-in al unirse
    'recarga_bot',      -- bot recargando en mesa (informativo)
    'ajuste'            -- ajuste manual por admin
);

CREATE TYPE movimiento_estado AS ENUM ('pendiente','aprobado','rechazado','procesando');

CREATE TABLE movimientos (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id      UUID            NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    tipo            movimiento_tipo NOT NULL,
    monto           NUMERIC(14,2)   NOT NULL,            -- positivo = ingreso, negativo = egreso
    saldo_antes     NUMERIC(14,2)   NOT NULL,
    saldo_despues   NUMERIC(14,2)   NOT NULL,
    estado          movimiento_estado NOT NULL DEFAULT 'aprobado',
    -- Referencias opcionales
    mesa_id         UUID            REFERENCES mesas(id),
    mano_id         UUID            REFERENCES manos(id),
    apuesta_id      UUID            REFERENCES apuestas(id),
    -- Datos de pago (depósito/retiro)
    cbu_destino     VARCHAR(22),
    referencia_pago VARCHAR(80),                         -- ID de Galio Pay
    descripcion     TEXT,
    -- Timestamps
    creado_en       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    procesado_en    TIMESTAMPTZ
);

CREATE INDEX idx_movimientos_usuario ON movimientos (usuario_id);
CREATE INDEX idx_movimientos_tipo    ON movimientos (tipo);
CREATE INDEX idx_movimientos_fecha   ON movimientos (creado_en DESC);


-- ══════════════════════════════════════════════════════════════════
-- 8. HISTORIAL DE CHAT DE MESA
-- ══════════════════════════════════════════════════════════════════

CREATE TABLE chat_mesa (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    mesa_id         UUID            NOT NULL REFERENCES mesas(id) ON DELETE CASCADE,
    mano_id         UUID            REFERENCES manos(id) ON DELETE SET NULL,
    autor_nombre    VARCHAR(60)     NOT NULL,
    autor_emoji     VARCHAR(10),
    autor_color     VARCHAR(7),
    es_bot          BOOLEAN         NOT NULL DEFAULT FALSE,
    mensaje         TEXT            NOT NULL,
    tipo_mensaje    VARCHAR(20)     DEFAULT 'chat',      -- chat, reaction, ambient, bubble
    creado_en       TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_chat_mesa  ON chat_mesa (mesa_id, creado_en DESC);


-- ══════════════════════════════════════════════════════════════════
-- 9. ESTADÍSTICAS DE JUGADOR (materializada)
-- ══════════════════════════════════════════════════════════════════

CREATE TABLE estadisticas_jugador (
    usuario_id          UUID        PRIMARY KEY REFERENCES usuarios(id) ON DELETE CASCADE,
    manos_jugadas       INTEGER     NOT NULL DEFAULT 0,
    manos_ganadas       INTEGER     NOT NULL DEFAULT 0,
    manos_perdidas      INTEGER     NOT NULL DEFAULT 0,
    manos_empatadas     INTEGER     NOT NULL DEFAULT 0,
    manos_pasadas       INTEGER     NOT NULL DEFAULT 0,    -- spread=0, pasa
    total_apostado      NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_ganado        NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_perdido       NUMERIC(14,2) NOT NULL DEFAULT 0,
    racha_actual        SMALLINT    NOT NULL DEFAULT 0,    -- >0 ganando, <0 perdiendo
    racha_max_ganadora  SMALLINT    NOT NULL DEFAULT 0,
    racha_max_perdedora SMALLINT    NOT NULL DEFAULT 0,
    apuesta_max         NUMERIC(14,2) NOT NULL DEFAULT 0,
    mesas_jugadas       INTEGER     NOT NULL DEFAULT 0,
    actualizado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ══════════════════════════════════════════════════════════════════
-- 10. CONFIGURACIÓN DE CASA (HOUSE EDGE)
-- ══════════════════════════════════════════════════════════════════

CREATE TABLE house_config (
    clave           VARCHAR(60)     PRIMARY KEY,
    valor           NUMERIC(10,4)   NOT NULL,
    descripcion     TEXT,
    actualizado_en  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

INSERT INTO house_config (clave, valor, descripcion) VALUES
    ('base_lose',        0.7800, 'Probabilidad base de pérdida del jugador humano'),
    ('cpu_lose',         0.4200, 'Probabilidad de pérdida de bots CPU'),
    ('streak_bonus',     0.0600, 'Penalidad extra por racha ganadora'),
    ('max_consec_loss',  5,      'Pérdidas consecutivas máx. antes de dar una ganancia'),
    ('warmup_hands',     3,      'Manos iniciales con menor probabilidad de pérdida'),
    ('session_bet_th1',  8000,   'Umbral 1 apuesta de sesión (+5% pérdida)'),
    ('session_bet_th2',  20000,  'Umbral 2 apuesta de sesión (+3% pérdida)'),
    ('pot_big_threshold',30000,  'Pozo a partir del cual un bot SIEMPRE gana'),
    -- Tramos de apuesta (bonus de pérdida)
    ('bet_tier_0_max',   199,    'Apuesta chica: sin penalidad'),
    ('bet_tier_1_min',   200,    'Apuesta media mín'),
    ('bet_tier_1_max',   499,    'Apuesta media máx'),
    ('bet_tier_1_bonus', 0.04,   'Bonus pérdida apuesta media'),
    ('bet_tier_2_min',   500,    'Apuesta moderada mín'),
    ('bet_tier_2_max',   999,    'Apuesta moderada máx'),
    ('bet_tier_2_bonus', 0.08,   'Bonus pérdida apuesta moderada'),
    ('bet_tier_3_min',   1000,   'Apuesta grande mín'),
    ('bet_tier_3_max',   1999,   'Apuesta grande máx'),
    ('bet_tier_3_bonus', 0.11,   'Bonus pérdida apuesta grande'),
    ('bet_tier_4_min',   2000,   'Apuesta muy grande mín'),
    ('bet_tier_4_max',   4999,   'Apuesta muy grande máx'),
    ('bet_tier_4_bonus', 0.14,   'Bonus pérdida apuesta muy grande'),
    ('bet_tier_5_min',   5000,   'All-in mín'),
    ('bet_tier_5_bonus', 0.17,   'Bonus pérdida all-in'),
    -- Wallet
    ('min_deposito',     1000,   'Mínimo de recarga'),
    ('min_retiro',       5000,   'Mínimo de retiro'),
    ('saldo_inicial',    2000,   'Saldo al registrarse');


-- ══════════════════════════════════════════════════════════════════
-- 11. BOTS DISPONIBLES (catálogo)
-- ══════════════════════════════════════════════════════════════════

CREATE TYPE bot_estilo AS ENUM ('gambler','bold','balanced','cautious');

CREATE TABLE bots (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          VARCHAR(60)     NOT NULL,
    emoji           VARCHAR(10)     NOT NULL,
    color_hex       VARCHAR(7)      NOT NULL,
    ciudad          VARCHAR(60),
    estilo          bot_estilo      NOT NULL,
    think_min_ms    INTEGER         NOT NULL DEFAULT 300,
    think_max_ms    INTEGER         NOT NULL DEFAULT 1200,
    trait           TEXT,
    -- Frases de chat (JSON array por categoría)
    chat_think      JSONB,   -- mensajes mientras piensa
    chat_bet        JSONB,   -- al apostar
    chat_win        JSONB,   -- al ganar
    chat_lose       JSONB,   -- al perder
    chat_tie        JSONB,   -- empate
    chat_big        JSONB,   -- rango amplio
    chat_small      JSONB,   -- rango cerrado
    react_win       VARCHAR(10),
    react_lose      VARCHAR(10),
    react_tie       VARCHAR(10),
    activo          BOOLEAN         NOT NULL DEFAULT TRUE
);

-- Seed de bots (extraídos del HTML)
INSERT INTO bots (nombre, emoji, color_hex, ciudad, estilo, think_min_ms, think_max_ms, trait,
    chat_think, chat_bet, chat_win, chat_lose, chat_tie, chat_big, chat_small,
    react_win, react_lose, react_tie)
VALUES
(
    'Marcos D.','🎩','#c9a84c','Buenos Aires','bold',400,1000,
    'El clásico del club — conoce cada carta de memoria',
    '["Mmm...","Analizando...","Veamos..."]',
    '["Apuesto con confianza.","Esta es mía.","Va."]',
    '["Sabía que iba.","Como siempre.","La experiencia no falla."]',
    '["Mala suerte.","Habrá próxima.","No siempre se gana."]',
    '["Empate... curioso."]',
    '["Rango amplio, apuesto fuerte.","Hay que aprovechar esto."]',
    '["Rango cerrado, paso suave.","Poco margen."]',
    '🎩','😤','🤝'
),(
    'Valentina S.','💃','#e74c3c','Córdoba','cautious',600,1500,
    'Cautelosa pero sorprende cuando la subestiman',
    '["Pensando...","No me apures.","Un momento."]',
    '["Apuesto poco, pero seguro.","Con cautela.","No me arriesgo de más."]',
    '["¡Qué bien!","La paciencia paga.","¡Sabía que iba!"]',
    '["Qué mala suerte...","Próxima vez.","No puedo creerlo."]',
    '["Empate, no está mal."]',
    '["Rango amplio... quizás apuesto un poco más."]',
    '["Rango muy cerrado, paso.","Difícil apostar esto."]',
    '💃','😞','🤷'
),(
    'Rodrigo M.','🦁','#f39c12','Rosario','gambler',200,500,
    'El apostador compulsivo — nunca se arrepiente de una apuesta grande',
    '["¡Vamos!","¡Sin dudar!","¡No hay tiempo que perder!"]',
    '["¡Todo adentro!","¡Al máximo!","¡Ahora o nunca!"]',
    '["¡BUENÍSIMO!","¡Sabía que iba!","¡El pozo es mío!"]',
    '["¡Mala!","¡La próxima la recupero!","¡No importa, sigo!"]',
    '["¡Empate? Igual apuesto!"]',
    '["¡Rango enorme, pongo todo!","¡Esto es fácil!"]',
    '["¡Qué mala carta! igual apuesto algo."]',
    '🔥','😤','😒'
),(
    'Elena K.','🌸','#9b59b6','Mendoza','balanced',500,1200,
    'Equilibrada — lee bien a los demás jugadores',
    '["Hmm...","Calculando...","Veamos las opciones."]',
    '["Apuesto según el rango.","Una apuesta razonable.","Según las cartas."]',
    '["¡Perfecto!","El rango lo decía.","Bien jugado."]',
    '["Una lástima.","Mano difícil.","Suerte para la próxima."]',
    '["Empate, interesante."]',
    '["Rango amplio, apuesto bien.","Hay que aprovechar."]',
    '["Rango estrecho...","Poco para apostar."]',
    '🌸','😔','🤔'
),(
    'Diego T.','🎯','#27ae60','Tucumán','bold',350,900,
    'Preciso y directo — apuesta cuando está seguro',
    '["Analizando...","Dame un segundo.","Calculando."]',
    '["Va de una.","Seguro.","Apuesto."]',
    '["¡Certero!","Como calculé.","Bien."]',
    '["Erré el cálculo.","Mala.","Perdí."]',
    '["Empate esperado."]',
    '["Rango claro, apuesto fuerte."]',
    '["Rango cerrado, apuesta mínima."]',
    '🎯','😑','🔄'
),(
    'Sebastián R.','🧔','#27ae60','Corrientes','gambler',200,600,
    'Streamer — juega en vivo para sus seguidores',
    '["¡Chat qué hago!","¡Votando en stream!","¡La gente dice todo in!"]',
    '["¡Por el stream!","¡Para los subs!","¡Van a flipar!"]',
    '["¡CLIP! ¡CLIP!","¡Los subs están locos!","¡KEKW ganamos!"]',
    '["¡Fue contenido igual!","¡F en el chat!","¡Al menos fue divertido!"]',
    '["¡Momento tenso para los subs!"]',
    '["¡Chat esto es EZ!","¡Todo in necesario!"]',
    '["¡Chat dicen que vaya igual!"]',
    '🎮','💀','😅'
);


-- ══════════════════════════════════════════════════════════════════
-- 12. SOLICITUDES DE RETIRO (flujo de aprobación)
-- ══════════════════════════════════════════════════════════════════

CREATE TYPE retiro_estado AS ENUM ('pendiente','procesando','aprobado','rechazado');

CREATE TABLE retiros (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id      UUID            NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    monto           NUMERIC(14,2)   NOT NULL CHECK (monto >= 5000),
    cbu             VARCHAR(22)     NOT NULL,
    estado          retiro_estado   NOT NULL DEFAULT 'pendiente',
    referencia_pago VARCHAR(80),
    motivo_rechazo  TEXT,
    movimiento_id   UUID            REFERENCES movimientos(id),
    solicitado_en   TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    procesado_en    TIMESTAMPTZ
);

CREATE INDEX idx_retiros_usuario ON retiros (usuario_id);
CREATE INDEX idx_retiros_estado  ON retiros (estado);


-- ══════════════════════════════════════════════════════════════════
-- ═══════════════════  FUNCIONES  ════════════════════════════════
-- ══════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────
-- F1. Registrar usuario nuevo
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION registrar_usuario(
    p_username   VARCHAR,
    p_password   VARCHAR,  -- en texto plano, se hashea aquí
    p_nombre     VARCHAR,
    p_alias      VARCHAR,
    p_cbu        VARCHAR   DEFAULT NULL,
    p_telefono   VARCHAR   DEFAULT NULL,
    p_provincia  VARCHAR   DEFAULT NULL,
    p_localidad  VARCHAR   DEFAULT NULL,
    p_saldo_ini  NUMERIC   DEFAULT 2000
)
RETURNS TABLE(usuario_id UUID, username VARCHAR, alias VARCHAR, error TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_id  UUID;
    v_min NUMERIC;
BEGIN
    -- Leer mínimo de saldo desde config
    SELECT valor INTO v_min FROM house_config WHERE clave = 'min_deposito';
    v_min := COALESCE(v_min, 1000);

    IF p_saldo_ini < v_min THEN
        RETURN QUERY SELECT NULL::UUID, NULL::VARCHAR, NULL::VARCHAR,
            'Saldo inicial mínimo: $' || v_min::TEXT;
        RETURN;
    END IF;

    -- Verificar unicidad
    IF EXISTS (SELECT 1 FROM usuarios WHERE LOWER(username) = LOWER(p_username)) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::VARCHAR, NULL::VARCHAR, 'Usuario ya existe';
        RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM usuarios WHERE LOWER(alias) = LOWER(p_alias)) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::VARCHAR, NULL::VARCHAR, 'Alias ya en uso';
        RETURN;
    END IF;

    INSERT INTO usuarios (username, password_hash, nombre, alias, cbu, telefono,
                          provincia, localidad, saldo, total_depositado, creado_en)
    VALUES (
        LOWER(p_username),
        crypt(p_password, gen_salt('bf', 10)),
        p_nombre, p_alias, p_cbu, p_telefono, p_provincia, p_localidad,
        p_saldo_ini, p_saldo_ini, NOW()
    )
    RETURNING id INTO v_id;

    -- Estadísticas iniciales
    INSERT INTO estadisticas_jugador (usuario_id) VALUES (v_id);

    -- Movimiento de depósito inicial
    INSERT INTO movimientos (usuario_id, tipo, monto, saldo_antes, saldo_despues,
                             descripcion, creado_en, procesado_en)
    VALUES (v_id, 'deposito', p_saldo_ini, 0, p_saldo_ini,
            'Saldo inicial al registrarse', NOW(), NOW());

    RETURN QUERY SELECT v_id, LOWER(p_username)::VARCHAR, p_alias::VARCHAR, NULL::TEXT;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F2. Login con usuario y contraseña
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION login(
    p_username  VARCHAR,
    p_password  VARCHAR,
    p_ip        INET    DEFAULT NULL,
    p_ua        TEXT    DEFAULT NULL
)
RETURNS TABLE(
    ok          BOOLEAN,
    usuario_id  UUID,
    token       TEXT,
    saldo       NUMERIC,
    alias       VARCHAR,
    error       TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_user  usuarios%ROWTYPE;
    v_token TEXT;
BEGIN
    SELECT * INTO v_user
    FROM usuarios
    WHERE LOWER(username) = LOWER(p_username)
      AND activo = TRUE;

    IF NOT FOUND OR v_user.password_hash <> crypt(p_password, v_user.password_hash) THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::TEXT, NULL::NUMERIC, NULL::VARCHAR,
                            'Usuario o contraseña incorrectos';
        RETURN;
    END IF;

    -- Generar token seguro
    v_token := encode(gen_random_bytes(48), 'hex');

    -- Invalidar sesiones viejas del mismo usuario (opcional: mantener multi-device)
    UPDATE sesiones SET activa = FALSE WHERE usuario_id = v_user.id AND activa = TRUE;

    INSERT INTO sesiones (usuario_id, token, ip, user_agent)
    VALUES (v_user.id, v_token, p_ip, p_ua);

    -- Actualizar último acceso
    UPDATE usuarios SET ultimo_acceso = NOW() WHERE id = v_user.id;

    RETURN QUERY SELECT TRUE, v_user.id, v_token, v_user.saldo, v_user.alias, NULL::TEXT;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F3. Logout (invalidar sesión)
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION logout(p_token TEXT)
RETURNS VOID LANGUAGE SQL AS $$
    UPDATE sesiones SET activa = FALSE WHERE token = p_token;
$$;


-- ──────────────────────────────────────────────────────────────
-- F4. Validar sesión activa → devuelve datos del usuario
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION validar_sesion(p_token TEXT)
RETURNS TABLE(
    valida      BOOLEAN,
    usuario_id  UUID,
    username    VARCHAR,
    alias       VARCHAR,
    saldo       NUMERIC,
    nombre      VARCHAR
)
LANGUAGE plpgsql AS $$
DECLARE
    v_sess sesiones%ROWTYPE;
    v_user usuarios%ROWTYPE;
BEGIN
    SELECT * INTO v_sess
    FROM sesiones
    WHERE token = p_token
      AND activa = TRUE
      AND expira_en > NOW();

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::VARCHAR, NULL::VARCHAR,
                            NULL::NUMERIC, NULL::VARCHAR;
        RETURN;
    END IF;

    SELECT * INTO v_user FROM usuarios WHERE id = v_sess.usuario_id AND activo = TRUE;

    RETURN QUERY SELECT TRUE, v_user.id, v_user.username, v_user.alias,
                        v_user.saldo, v_user.nombre;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F5. Procesar depósito (recarga de saldo)
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION procesar_deposito(
    p_usuario_id    UUID,
    p_monto         NUMERIC,
    p_referencia    VARCHAR DEFAULT NULL
)
RETURNS TABLE(ok BOOLEAN, saldo_nuevo NUMERIC, error TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_min   NUMERIC;
    v_saldo NUMERIC;
BEGIN
    SELECT valor INTO v_min FROM house_config WHERE clave = 'min_deposito';
    v_min := COALESCE(v_min, 1000);

    IF p_monto < v_min THEN
        RETURN QUERY SELECT FALSE, NULL::NUMERIC,
            'Monto mínimo de recarga: $' || v_min::TEXT;
        RETURN;
    END IF;

    SELECT saldo INTO v_saldo FROM usuarios WHERE id = p_usuario_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::NUMERIC, 'Usuario no encontrado';
        RETURN;
    END IF;

    UPDATE usuarios
    SET saldo             = saldo + p_monto,
        total_depositado  = total_depositado + p_monto
    WHERE id = p_usuario_id
    RETURNING saldo INTO v_saldo;

    INSERT INTO movimientos (usuario_id, tipo, monto, saldo_antes, saldo_despues,
                             referencia_pago, descripcion, procesado_en)
    VALUES (p_usuario_id, 'deposito', p_monto, v_saldo - p_monto, v_saldo,
            p_referencia, 'Recarga vía Galio Pay', NOW());

    RETURN QUERY SELECT TRUE, v_saldo, NULL::TEXT;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F6. Solicitar retiro
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION solicitar_retiro(
    p_usuario_id UUID,
    p_monto      NUMERIC,
    p_cbu        VARCHAR
)
RETURNS TABLE(ok BOOLEAN, retiro_id UUID, error TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_min   NUMERIC;
    v_saldo NUMERIC;
    v_rid   UUID;
    v_mov   UUID;
BEGIN
    SELECT valor INTO v_min FROM house_config WHERE clave = 'min_retiro';
    v_min := COALESCE(v_min, 5000);

    IF p_monto < v_min THEN
        RETURN QUERY SELECT FALSE, NULL::UUID,
            'Monto mínimo de retiro: $' || v_min::TEXT;
        RETURN;
    END IF;

    SELECT saldo INTO v_saldo FROM usuarios
    WHERE id = p_usuario_id AND activo = TRUE FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, 'Usuario no encontrado';
        RETURN;
    END IF;

    IF v_saldo < p_monto THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, 'Saldo insuficiente';
        RETURN;
    END IF;

    -- Descontar saldo
    UPDATE usuarios
    SET saldo           = saldo - p_monto,
        total_retirado  = total_retirado + p_monto
    WHERE id = p_usuario_id;

    -- Movimiento
    INSERT INTO movimientos (usuario_id, tipo, monto, saldo_antes, saldo_despues,
                             cbu_destino, descripcion)
    VALUES (p_usuario_id, 'retiro', -p_monto, v_saldo, v_saldo - p_monto,
            p_cbu, 'Retiro solicitado vía Galio Pay')
    RETURNING id INTO v_mov;

    -- Solicitud de retiro
    INSERT INTO retiros (usuario_id, monto, cbu, movimiento_id)
    VALUES (p_usuario_id, p_monto, p_cbu, v_mov)
    RETURNING id INTO v_rid;

    RETURN QUERY SELECT TRUE, v_rid, NULL::TEXT;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F7. Crear mesa
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crear_mesa(
    p_nombre        VARCHAR,
    p_categoria     mesa_categoria,
    p_buy_in        NUMERIC,
    p_max_asientos  SMALLINT
)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO mesas (nombre, categoria, buy_in, max_asientos, estado, pozo)
    VALUES (p_nombre, p_categoria, p_buy_in, p_max_asientos, 'open', 0)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F8. Unirse a una mesa (buy-in)
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION unirse_mesa(
    p_usuario_id UUID,
    p_mesa_id    UUID
)
RETURNS TABLE(ok BOOLEAN, asiento_id UUID, error TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_mesa    mesas%ROWTYPE;
    v_user    usuarios%ROWTYPE;
    v_asiento UUID;
    v_asientos_actuales INT;
BEGIN
    SELECT * INTO v_mesa FROM mesas WHERE id = p_mesa_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, 'Mesa no encontrada';
        RETURN;
    END IF;

    IF v_mesa.estado IN ('full','playing','closed') THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, 'Mesa no disponible';
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_asientos_actuales
    FROM mesa_asientos
    WHERE mesa_id = p_mesa_id AND activo = TRUE AND tipo = 'humano';

    IF v_asientos_actuales >= v_mesa.max_asientos THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, 'Mesa completa';
        RETURN;
    END IF;

    SELECT * INTO v_user FROM usuarios WHERE id = p_usuario_id FOR UPDATE;
    IF v_user.saldo < v_mesa.buy_in THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, 'Saldo insuficiente para el buy-in';
        RETURN;
    END IF;

    -- Descontar buy-in
    UPDATE usuarios SET saldo = saldo - v_mesa.buy_in WHERE id = p_usuario_id;
    UPDATE mesas SET pozo = pozo + v_mesa.buy_in,
                    ultima_actividad = NOW()
    WHERE id = p_mesa_id;

    INSERT INTO mesa_asientos (mesa_id, usuario_id, nombre_display, tipo, saldo_en_mesa)
    SELECT p_mesa_id, p_usuario_id, u.alias, 'humano', v_mesa.buy_in
    FROM usuarios u WHERE u.id = p_usuario_id
    RETURNING id INTO v_asiento;

    -- Movimiento
    INSERT INTO movimientos (usuario_id, tipo, monto, saldo_antes, saldo_despues,
                             mesa_id, descripcion)
    VALUES (p_usuario_id, 'entrada_mesa', -v_mesa.buy_in,
            v_user.saldo, v_user.saldo - v_mesa.buy_in,
            p_mesa_id, 'Buy-in mesa ' || v_mesa.nombre);

    -- Actualizar estado mesa
    v_asientos_actuales := v_asientos_actuales + 1;
    IF v_asientos_actuales >= v_mesa.max_asientos THEN
        UPDATE mesas SET estado = 'full' WHERE id = p_mesa_id;
    ELSIF v_asientos_actuales >= v_mesa.max_asientos - 2 THEN
        UPDATE mesas SET estado = 'filling' WHERE id = p_mesa_id;
    END IF;

    RETURN QUERY SELECT TRUE, v_asiento, NULL::TEXT;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F9. Iniciar mano
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION iniciar_mano(
    p_mesa_id       UUID,
    p_carta1_palo   carta_palo,
    p_carta1_valor  carta_valor,
    p_carta2_palo   carta_palo,
    p_carta2_valor  carta_valor
)
RETURNS TABLE(mano_id UUID, numero_mano INTEGER, rango_lo SMALLINT,
              rango_hi SMALLINT, spread SMALLINT)
LANGUAGE plpgsql AS $$
DECLARE
    v_id    UUID;
    v_num   INT;
    -- Valores numéricos de la baraja española (Ases=1, J=8,Q=9,K=10 + 2..7)
    v_vals  INT[] := ARRAY[1,2,3,4,5,6,7,8,9,10,11,12]; -- placeholder
    v_lo    SMALLINT;
    v_hi    SMALLINT;
    v_sp    SMALLINT;
BEGIN
    SELECT COALESCE(MAX(numero_mano), 0) + 1 INTO v_num
    FROM manos WHERE mesa_id = p_mesa_id;

    -- Calcular lo/hi/spread según valor de cartas
    -- Mapeamos: A=1,2=2,...,7=7,J=8,Q=9,K=10
    WITH vals(v, n) AS (VALUES
        ('A'::carta_valor,1),('2',2),('3',3),('4',4),('5',5),
        ('6',6),('7',7),('J',8),('Q',9),('K',10)
    )
    SELECT
        LEAST(v1.n, v2.n)::SMALLINT,
        GREATEST(v1.n, v2.n)::SMALLINT,
        (GREATEST(v1.n, v2.n) - LEAST(v1.n, v2.n) - 1)::SMALLINT
    INTO v_lo, v_hi, v_sp
    FROM vals v1, vals v2
    WHERE v1.v = p_carta1_valor AND v2.v = p_carta2_valor;

    INSERT INTO manos (mesa_id, numero_mano,
                       carta1_palo, carta1_valor, carta2_palo, carta2_valor,
                       rango_lo, rango_hi, spread, pozo_inicio)
    SELECT p_mesa_id, v_num,
           p_carta1_palo, p_carta1_valor, p_carta2_palo, p_carta2_valor,
           v_lo, v_hi, v_sp, m.pozo
    FROM mesas m WHERE m.id = p_mesa_id
    RETURNING manos.id INTO v_id;

    UPDATE mesas SET estado = 'playing', ultima_actividad = NOW()
    WHERE id = p_mesa_id;

    RETURN QUERY SELECT v_id, v_num, v_lo, v_hi, v_sp;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F10. Registrar apuesta y resolver resultado
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION registrar_apuesta(
    p_mano_id           UUID,
    p_asiento_id        UUID,
    p_usuario_id        UUID,       -- NULL si es bot
    p_es_bot            BOOLEAN,
    p_monto             NUMERIC,
    p_carta_media_palo  carta_palo,
    p_carta_media_valor carta_valor,
    p_resultado         resultado_apuesta
)
RETURNS TABLE(ok BOOLEAN, ganancia_neta NUMERIC, saldo_nuevo NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE
    v_mano      manos%ROWTYPE;
    v_saldo_ant NUMERIC;
    v_saldo_nue NUMERIC;
    v_ganancia  NUMERIC;
    v_apuesta_id UUID;
BEGIN
    SELECT * INTO v_mano FROM manos WHERE id = p_mano_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, NULL::NUMERIC, NULL::NUMERIC; RETURN; END IF;

    -- Saldo actual del jugador humano
    IF NOT p_es_bot AND p_usuario_id IS NOT NULL THEN
        SELECT saldo INTO v_saldo_ant FROM usuarios WHERE id = p_usuario_id FOR UPDATE;
    ELSE
        SELECT saldo_en_mesa INTO v_saldo_ant FROM mesa_asientos WHERE id = p_asiento_id;
    END IF;

    -- Calcular ganancia neta
    CASE p_resultado
        WHEN 'win'  THEN v_ganancia :=  p_monto;   -- recupera apuesta + igual
        WHEN 'lose' THEN v_ganancia := -p_monto;
        WHEN 'tie'  THEN v_ganancia :=  0;
        WHEN 'pass' THEN v_ganancia :=  0;
    END CASE;

    v_saldo_nue := v_saldo_ant + v_ganancia;

    -- Actualizar saldo jugador humano
    IF NOT p_es_bot AND p_usuario_id IS NOT NULL THEN
        UPDATE usuarios
        SET saldo         = v_saldo_nue,
            total_manos   = total_manos + 1
        WHERE id = p_usuario_id;

        -- Movimiento de billetera
        INSERT INTO movimientos (usuario_id, tipo, monto, saldo_antes, saldo_despues,
                                 mesa_id, mano_id, descripcion)
        VALUES (
            p_usuario_id,
            CASE p_resultado WHEN 'win' THEN 'ganancia' ELSE 'apuesta' END,
            CASE p_resultado WHEN 'win' THEN v_ganancia ELSE -p_monto END,
            v_saldo_ant, v_saldo_nue,
            v_mano.mesa_id, p_mano_id,
            'Mano #' || v_mano.numero_mano::TEXT || ' — ' || p_resultado::TEXT
        );

        -- Actualizar estadísticas
        PERFORM actualizar_estadisticas(p_usuario_id, p_resultado, p_monto, v_ganancia);
    ELSE
        UPDATE mesa_asientos SET saldo_en_mesa = v_saldo_nue WHERE id = p_asiento_id;
    END IF;

    -- Actualizar pozo de la mesa
    IF p_resultado = 'win' THEN
        UPDATE mesas SET pozo = pozo - p_monto WHERE id = v_mano.mesa_id;
    ELSIF p_resultado IN ('lose','pass') THEN
        UPDATE mesas SET pozo = pozo + p_monto WHERE id = v_mano.mesa_id;
    END IF;

    -- Registrar apuesta
    INSERT INTO apuestas (mano_id, asiento_id, usuario_id, es_bot,
                          carta_media_palo, carta_media_valor,
                          monto_apostado, resultado, ganancia_neta,
                          saldo_antes, saldo_despues)
    VALUES (p_mano_id, p_asiento_id, p_usuario_id, p_es_bot,
            p_carta_media_palo, p_carta_media_valor,
            p_monto, p_resultado, v_ganancia,
            v_saldo_ant, v_saldo_nue)
    RETURNING id INTO v_apuesta_id;

    RETURN QUERY SELECT TRUE, v_ganancia, v_saldo_nue;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F11. Finalizar mano
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION finalizar_mano(
    p_mano_id           UUID,
    p_carta_media_palo  carta_palo,
    p_carta_media_valor carta_valor,
    p_ganador_nombre    VARCHAR,
    p_ganador_tipo      asiento_tipo
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_mesa_id UUID;
BEGIN
    UPDATE manos
    SET carta_media_palo  = p_carta_media_palo,
        carta_media_valor = p_carta_media_valor,
        ganador_nombre    = p_ganador_nombre,
        ganador_tipo      = p_ganador_tipo,
        pozo_final        = (SELECT pozo FROM mesas WHERE id = mesa_id),
        finalizada_en     = NOW()
    WHERE id = p_mano_id
    RETURNING mesa_id INTO v_mesa_id;

    UPDATE mesas
    SET manos_jugadas    = manos_jugadas + 1,
        ultima_actividad = NOW()
    WHERE id = v_mesa_id;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F12. Actualizar estadísticas de jugador
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION actualizar_estadisticas(
    p_usuario_id UUID,
    p_resultado  resultado_apuesta,
    p_monto      NUMERIC,
    p_ganancia   NUMERIC
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_racha INT;
BEGIN
    SELECT racha_actual INTO v_racha
    FROM estadisticas_jugador WHERE usuario_id = p_usuario_id;

    -- Calcular nueva racha
    CASE p_resultado
        WHEN 'win'  THEN v_racha := CASE WHEN v_racha >= 0 THEN v_racha + 1 ELSE 1 END;
        WHEN 'lose' THEN v_racha := CASE WHEN v_racha <= 0 THEN v_racha - 1 ELSE -1 END;
        ELSE             v_racha := 0;
    END CASE;

    INSERT INTO estadisticas_jugador (
        usuario_id, manos_jugadas, manos_ganadas, manos_perdidas,
        manos_empatadas, manos_pasadas, total_apostado, total_ganado,
        total_perdido, racha_actual, racha_max_ganadora, racha_max_perdedora,
        apuesta_max, actualizado_en
    )
    VALUES (
        p_usuario_id, 1,
        CASE WHEN p_resultado='win'  THEN 1 ELSE 0 END,
        CASE WHEN p_resultado='lose' THEN 1 ELSE 0 END,
        CASE WHEN p_resultado='tie'  THEN 1 ELSE 0 END,
        CASE WHEN p_resultado='pass' THEN 1 ELSE 0 END,
        p_monto,
        CASE WHEN p_ganancia > 0 THEN p_ganancia ELSE 0 END,
        CASE WHEN p_ganancia < 0 THEN ABS(p_ganancia) ELSE 0 END,
        v_racha,
        GREATEST(0, v_racha),
        LEAST(0, v_racha) * -1,
        p_monto,
        NOW()
    )
    ON CONFLICT (usuario_id) DO UPDATE SET
        manos_jugadas       = estadisticas_jugador.manos_jugadas       + 1,
        manos_ganadas       = estadisticas_jugador.manos_ganadas       + CASE WHEN p_resultado='win'  THEN 1 ELSE 0 END,
        manos_perdidas      = estadisticas_jugador.manos_perdidas      + CASE WHEN p_resultado='lose' THEN 1 ELSE 0 END,
        manos_empatadas     = estadisticas_jugador.manos_empatadas     + CASE WHEN p_resultado='tie'  THEN 1 ELSE 0 END,
        manos_pasadas       = estadisticas_jugador.manos_pasadas       + CASE WHEN p_resultado='pass' THEN 1 ELSE 0 END,
        total_apostado      = estadisticas_jugador.total_apostado      + p_monto,
        total_ganado        = estadisticas_jugador.total_ganado        + CASE WHEN p_ganancia > 0 THEN p_ganancia ELSE 0 END,
        total_perdido       = estadisticas_jugador.total_perdido       + CASE WHEN p_ganancia < 0 THEN ABS(p_ganancia) ELSE 0 END,
        racha_actual        = v_racha,
        racha_max_ganadora  = GREATEST(estadisticas_jugador.racha_max_ganadora,  GREATEST(0, v_racha)),
        racha_max_perdedora = GREATEST(estadisticas_jugador.racha_max_perdedora, GREATEST(0, v_racha * -1)),
        apuesta_max         = GREATEST(estadisticas_jugador.apuesta_max, p_monto),
        actualizado_en      = NOW();
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F13. Calcular house edge para una apuesta dada
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION calcular_house_edge(
    p_monto         NUMERIC,
    p_racha         INT,
    p_session_bet   NUMERIC,
    p_mano_num      INT
)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
    v_base       NUMERIC;
    v_streak     NUMERIC;
    v_tier_bonus NUMERIC := 0;
    v_sess_bonus NUMERIC := 0;
    v_warmup     INT;
    v_result     NUMERIC;
BEGIN
    SELECT valor INTO v_base    FROM house_config WHERE clave = 'base_lose';
    SELECT valor INTO v_streak  FROM house_config WHERE clave = 'streak_bonus';
    SELECT valor INTO v_warmup  FROM house_config WHERE clave = 'warmup_hands';

    -- Manos de calentamiento
    IF p_mano_num <= v_warmup THEN
        RETURN 0.42;
    END IF;

    -- Bonus por racha ganadora
    v_result := v_base + (LEAST(GREATEST(p_racha, 0), 3) * v_streak);

    -- Bonus por tramo de apuesta
    SELECT valor INTO v_tier_bonus
    FROM house_config
    WHERE clave LIKE 'bet_tier_%_bonus'
      AND (SELECT valor FROM house_config WHERE clave = REPLACE(clave, '_bonus', '_min')) <= p_monto
      AND (
          NOT EXISTS (SELECT 1 FROM house_config WHERE clave = REPLACE(clave, '_bonus', '_max'))
          OR (SELECT valor FROM house_config WHERE clave = REPLACE(clave, '_bonus', '_max')) >= p_monto
      )
    ORDER BY (SELECT valor FROM house_config WHERE clave = REPLACE(clave, '_bonus', '_min')) DESC
    LIMIT 1;

    v_result := v_result + COALESCE(v_tier_bonus, 0);

    -- Bonus por apuesta de sesión
    IF p_session_bet > 20000 THEN v_sess_bonus := 0.08;
    ELSIF p_session_bet > 8000 THEN v_sess_bonus := 0.05;
    END IF;

    v_result := LEAST(v_result + v_sess_bonus, 0.94);

    RETURN v_result;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F14. Obtener historial de movimientos de un usuario
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION historial_movimientos(
    p_usuario_id UUID,
    p_limite     INT DEFAULT 30,
    p_offset     INT DEFAULT 0
)
RETURNS TABLE(
    tipo        movimiento_tipo,
    monto       NUMERIC,
    saldo_despues NUMERIC,
    descripcion TEXT,
    fecha       TIMESTAMPTZ
)
LANGUAGE SQL AS $$
    SELECT tipo, monto, saldo_despues, descripcion, creado_en
    FROM movimientos
    WHERE usuario_id = p_usuario_id
    ORDER BY creado_en DESC
    LIMIT p_limite OFFSET p_offset;
$$;

-- ─────────────────────────────────────────────────────────────
-- GALIOPAY: depósito pendiente + confirmación idempotente
-- ─────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS idx_movimientos_referencia_pago_unique
ON movimientos (referencia_pago)
WHERE referencia_pago IS NOT NULL;

CREATE OR REPLACE FUNCTION registrar_deposito_pendiente(
    p_usuario_id UUID,
    p_monto      NUMERIC,
    p_referencia VARCHAR
)
RETURNS TABLE(ok BOOLEAN, movimiento_id UUID, error TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_saldo NUMERIC;
    v_mov   UUID;
BEGIN
    IF p_monto < 1000 THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, 'Monto mínimo de recarga: $1000';
        RETURN;
    END IF;

    SELECT saldo INTO v_saldo
    FROM usuarios
    WHERE id = p_usuario_id AND activo = TRUE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, 'Usuario no encontrado';
        RETURN;
    END IF;

    INSERT INTO movimientos (
        usuario_id, tipo, monto, saldo_antes, saldo_despues,
        estado, referencia_pago, descripcion
    )
    VALUES (
        p_usuario_id, 'deposito', p_monto, v_saldo, v_saldo,
        'pendiente', p_referencia, 'Recarga pendiente vía Galio Pay'
    )
    ON CONFLICT (referencia_pago) WHERE referencia_pago IS NOT NULL
    DO UPDATE SET referencia_pago = EXCLUDED.referencia_pago
    RETURNING id INTO v_mov;

    RETURN QUERY SELECT TRUE, v_mov, NULL::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION confirmar_deposito_galiopay(
    p_referencia VARCHAR,
    p_payment_id VARCHAR DEFAULT NULL,
    p_usuario_id UUID DEFAULT NULL,
    p_monto      NUMERIC DEFAULT NULL
)
RETURNS TABLE(ok BOOLEAN, saldo_nuevo NUMERIC, error TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_mov movimientos%ROWTYPE;
    v_saldo NUMERIC;
BEGIN
    SELECT * INTO v_mov
    FROM movimientos
    WHERE referencia_pago = p_referencia
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::NUMERIC, 'Movimiento pendiente no encontrado';
        RETURN;
    END IF;

    IF p_usuario_id IS NOT NULL AND v_mov.usuario_id <> p_usuario_id THEN
        RETURN QUERY SELECT FALSE, NULL::NUMERIC, 'Usuario no coincide con la referencia';
        RETURN;
    END IF;

    IF p_monto IS NOT NULL AND ABS(v_mov.monto - p_monto) > 0.01 THEN
        RETURN QUERY SELECT FALSE, NULL::NUMERIC, 'Monto no coincide con la referencia';
        RETURN;
    END IF;

    SELECT saldo INTO v_saldo
    FROM usuarios
    WHERE id = v_mov.usuario_id
    FOR UPDATE;

    IF v_mov.estado = 'aprobado' THEN
        RETURN QUERY SELECT TRUE, v_saldo, NULL::TEXT;
        RETURN;
    END IF;

    UPDATE usuarios
    SET saldo = saldo + v_mov.monto,
        total_depositado = total_depositado + v_mov.monto
    WHERE id = v_mov.usuario_id
    RETURNING saldo INTO v_saldo;

    UPDATE movimientos
    SET estado = 'aprobado',
        saldo_despues = v_saldo,
        procesado_en = NOW(),
        descripcion = 'Recarga confirmada vía Galio Pay' ||
            CASE WHEN p_payment_id IS NULL THEN '' ELSE ' · Payment ID: ' || p_payment_id END
    WHERE id = v_mov.id;

    RETURN QUERY SELECT TRUE, v_saldo, NULL::TEXT;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- F15. Listar mesas activas para el lobby
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION listar_mesas_lobby()
RETURNS TABLE(
    mesa_id         UUID,
    nombre          VARCHAR,
    categoria       mesa_categoria,
    buy_in          NUMERIC,
    max_asientos    SMALLINT,
    asientos_ocupados INT,
    asientos_libres   INT,
    estado          mesa_estado,
    pozo            NUMERIC,
    manos_jugadas   INT,
    pct_ocupacion   INT
)
LANGUAGE SQL AS $$
    SELECT
        m.id,
        m.nombre,
        m.categoria,
        m.buy_in,
        m.max_asientos,
        COUNT(a.id)::INT                                        AS asientos_ocupados,
        (m.max_asientos - COUNT(a.id))::INT                     AS asientos_libres,
        m.estado,
        m.pozo,
        m.manos_jugadas,
        ROUND(COUNT(a.id)::NUMERIC / m.max_asientos * 100)::INT AS pct_ocupacion
    FROM mesas m
    LEFT JOIN mesa_asientos a ON a.mesa_id = m.id AND a.activo = TRUE AND a.tipo != 'espectador'
    WHERE m.estado NOT IN ('closed')
    GROUP BY m.id
    ORDER BY m.estado DESC, m.pozo DESC;
$$;


-- ══════════════════════════════════════════════════════════════════
-- VISTAS ÚTILES
-- ══════════════════════════════════════════════════════════════════

-- Vista de resumen de jugador para el lobby
CREATE OR REPLACE VIEW v_jugador_resumen AS
SELECT
    u.id,
    u.username,
    u.alias,
    u.nombre,
    u.saldo,
    u.total_depositado,
    u.total_retirado,
    u.total_manos,
    u.avatar_type,
    u.avatar_emoji,
    u.avatar_iniciales,
    u.avatar_color_idx,
    u.provincia,
    u.localidad,
    e.manos_ganadas,
    e.manos_perdidas,
    e.racha_actual,
    e.racha_max_ganadora,
    e.total_apostado,
    ROUND(
        CASE WHEN e.manos_jugadas > 0
             THEN e.manos_ganadas::NUMERIC / e.manos_jugadas * 100
             ELSE 0 END, 1
    ) AS win_rate_pct
FROM usuarios u
LEFT JOIN estadisticas_jugador e ON e.usuario_id = u.id
WHERE u.activo = TRUE;


-- Vista de últimas apuestas del jugador humano
CREATE OR REPLACE VIEW v_historial_apuestas AS
SELECT
    a.id,
    ap.usuario_id,
    u.alias,
    m_mesa.nombre   AS mesa_nombre,
    mn.numero_mano,
    a.monto_apostado,
    a.resultado,
    a.ganancia_neta,
    a.saldo_antes,
    a.saldo_despues,
    a.apostado_en
FROM apuestas a
JOIN manos mn         ON mn.id = a.mano_id
JOIN mesas m_mesa     ON m_mesa.id = mn.mesa_id
JOIN mesa_asientos ap ON ap.id = a.asiento_id
JOIN usuarios u       ON u.id = a.usuario_id
WHERE a.es_bot = FALSE
ORDER BY a.apostado_en DESC;


-- ══════════════════════════════════════════════════════════════════
-- ÍNDICES ADICIONALES DE PERFORMANCE
-- ══════════════════════════════════════════════════════════════════

CREATE INDEX idx_apuestas_resultado   ON apuestas (resultado);
CREATE INDEX idx_manos_finalizada     ON manos (finalizada_en DESC);
CREATE INDEX idx_movimientos_estado   ON movimientos (estado);
CREATE INDEX idx_retiros_solicitado   ON retiros (solicitado_en DESC);
CREATE INDEX idx_sesiones_expira      ON sesiones (expira_en) WHERE activa = TRUE;


-- ══════════════════════════════════════════════════════════════════
-- COMENTARIOS DE TABLA
-- ══════════════════════════════════════════════════════════════════

COMMENT ON TABLE usuarios      IS 'Jugadores registrados en El Intermedio';
COMMENT ON TABLE sesiones      IS 'Sesiones activas (tokens de autenticación)';
COMMENT ON TABLE mesas         IS 'Mesas de juego — generadas dinámicamente en el lobby';
COMMENT ON TABLE mesa_asientos IS 'Asientos ocupados por humanos y bots en cada mesa';
COMMENT ON TABLE manos         IS 'Cada ronda de juego (par de cartas + carta intermedia)';
COMMENT ON TABLE apuestas      IS 'Apuesta individual de cada jugador por mano';
COMMENT ON TABLE movimientos   IS 'Libro mayor de todos los movimientos de saldo';
COMMENT ON TABLE retiros       IS 'Solicitudes de retiro a CBU/CVU vía Galio Pay';
COMMENT ON TABLE bots          IS 'Catálogo de personajes bot del juego';
COMMENT ON TABLE house_config  IS 'Parámetros del motor de ventaja de la casa';
COMMENT ON TABLE estadisticas_jugador IS 'Estadísticas acumuladas por jugador humano';
COMMENT ON TABLE chat_mesa     IS 'Historial de mensajes del chat de mesa';

-- ══════════════════════════════════════════════════════════════════
-- FIN
-- ══════════════════════════════════════════════════════════════════
