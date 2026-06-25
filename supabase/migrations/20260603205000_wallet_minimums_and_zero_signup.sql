UPDATE house_config
SET valor = 5000
WHERE clave = 'min_deposito';

UPDATE house_config
SET valor = 10000
WHERE clave = 'min_retiro';

UPDATE house_config
SET valor = 0
WHERE clave = 'saldo_inicial';

CREATE OR REPLACE FUNCTION registrar_usuario(
    p_username   VARCHAR,
    p_password   VARCHAR,
    p_nombre     VARCHAR,
    p_alias      VARCHAR,
    p_cbu        VARCHAR   DEFAULT NULL,
    p_telefono   VARCHAR   DEFAULT NULL,
    p_provincia  VARCHAR   DEFAULT NULL,
    p_localidad  VARCHAR   DEFAULT NULL,
    p_saldo_ini  NUMERIC   DEFAULT 0
)
RETURNS TABLE(usuario_id UUID, username VARCHAR, alias VARCHAR, error TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_id UUID;
BEGIN
    IF p_saldo_ini < 0 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::VARCHAR, NULL::VARCHAR, 'Saldo inicial inválido';
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM usuarios u WHERE LOWER(u.username) = LOWER(p_username)) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::VARCHAR, NULL::VARCHAR, 'Usuario ya existe';
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM usuarios u WHERE LOWER(u.alias) = LOWER(p_alias)) THEN
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

    INSERT INTO estadisticas_jugador (usuario_id)
    VALUES (v_id)
    ON CONFLICT DO NOTHING;

    IF p_saldo_ini > 0 THEN
        INSERT INTO movimientos (usuario_id, tipo, monto, saldo_antes, saldo_despues,
                                 descripcion, creado_en, procesado_en)
        VALUES (v_id, 'deposito', p_saldo_ini, 0, p_saldo_ini,
                'Saldo inicial al registrarse', NOW(), NOW());
    END IF;

    RETURN QUERY SELECT v_id, LOWER(p_username)::VARCHAR, p_alias::VARCHAR, NULL::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION registrar_deposito_pendiente(
    p_usuario_id UUID,
    p_monto      NUMERIC,
    p_referencia VARCHAR
)
RETURNS TABLE(ok BOOLEAN, movimiento_id UUID, error TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_saldo NUMERIC;
    v_mov   UUID;
BEGIN
    IF p_monto < 5000 THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, 'Monto mínimo de recarga: $5000';
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
