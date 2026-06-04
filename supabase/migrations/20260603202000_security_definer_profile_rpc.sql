ALTER FUNCTION registrar_usuario(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMERIC)
SECURITY DEFINER
SET search_path = public;

ALTER FUNCTION login(VARCHAR, VARCHAR, INET, TEXT)
SECURITY DEFINER
SET search_path = public;

ALTER FUNCTION solicitar_retiro(UUID, NUMERIC, VARCHAR)
SECURITY DEFINER
SET search_path = public;

ALTER FUNCTION registrar_deposito_pendiente(UUID, NUMERIC, VARCHAR)
SECURITY DEFINER
SET search_path = public;

ALTER FUNCTION confirmar_deposito_galiopay(VARCHAR, VARCHAR, UUID, NUMERIC)
SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION obtener_perfil_usuario(p_usuario_id UUID)
RETURNS TABLE(
    id UUID,
    username VARCHAR,
    nombre VARCHAR,
    alias VARCHAR,
    cbu VARCHAR,
    telefono VARCHAR,
    provincia VARCHAR,
    localidad VARCHAR,
    avatar_type VARCHAR,
    avatar_emoji VARCHAR,
    avatar_iniciales VARCHAR,
    avatar_color_idx SMALLINT,
    avatar_photo_url TEXT,
    saldo NUMERIC,
    total_depositado NUMERIC,
    total_retirado NUMERIC,
    total_manos INTEGER,
    creado_en TIMESTAMPTZ
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT u.id, u.username, u.nombre, u.alias, u.cbu, u.telefono,
           u.provincia, u.localidad, u.avatar_type, u.avatar_emoji,
           u.avatar_iniciales, u.avatar_color_idx, u.avatar_photo_url,
           u.saldo, u.total_depositado, u.total_retirado, u.total_manos,
           u.creado_en
    FROM usuarios u
    WHERE u.id = p_usuario_id AND u.activo = TRUE;
$$;

CREATE OR REPLACE FUNCTION actualizar_perfil_usuario(
    p_usuario_id UUID,
    p_nombre VARCHAR,
    p_alias VARCHAR,
    p_cbu VARCHAR DEFAULT NULL,
    p_telefono VARCHAR DEFAULT NULL,
    p_provincia VARCHAR DEFAULT NULL,
    p_localidad VARCHAR DEFAULT NULL,
    p_avatar_type VARCHAR DEFAULT 'emoji',
    p_avatar_emoji VARCHAR DEFAULT NULL,
    p_avatar_iniciales VARCHAR DEFAULT NULL,
    p_avatar_color_idx SMALLINT DEFAULT 0,
    p_avatar_photo_url TEXT DEFAULT NULL,
    p_total_manos INTEGER DEFAULT 0
)
RETURNS TABLE(ok BOOLEAN, error TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RETURN QUERY SELECT FALSE, 'Nombre requerido';
        RETURN;
    END IF;

    IF p_alias IS NULL OR LENGTH(TRIM(p_alias)) = 0 THEN
        RETURN QUERY SELECT FALSE, 'Alias requerido';
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM usuarios u
        WHERE LOWER(u.alias) = LOWER(p_alias)
          AND u.id <> p_usuario_id
    ) THEN
        RETURN QUERY SELECT FALSE, 'Alias ya en uso';
        RETURN;
    END IF;

    UPDATE usuarios
    SET nombre = p_nombre,
        alias = p_alias,
        cbu = p_cbu,
        telefono = p_telefono,
        provincia = p_provincia,
        localidad = p_localidad,
        avatar_type = COALESCE(p_avatar_type, 'emoji'),
        avatar_emoji = p_avatar_emoji,
        avatar_iniciales = p_avatar_iniciales,
        avatar_color_idx = COALESCE(p_avatar_color_idx, 0),
        avatar_photo_url = p_avatar_photo_url,
        total_manos = GREATEST(total_manos, COALESCE(p_total_manos, 0)),
        ultimo_acceso = NOW()
    WHERE id = p_usuario_id AND activo = TRUE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Usuario no encontrado';
        RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, NULL::TEXT;
END;
$$;
