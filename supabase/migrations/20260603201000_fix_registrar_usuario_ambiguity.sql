CREATE OR REPLACE FUNCTION registrar_usuario(
    p_username   VARCHAR,
    p_password   VARCHAR,
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
    SELECT valor INTO v_min FROM house_config WHERE clave = 'min_deposito';
    v_min := COALESCE(v_min, 1000);

    IF p_saldo_ini < v_min THEN
        RETURN QUERY SELECT NULL::UUID, NULL::VARCHAR, NULL::VARCHAR,
            'Saldo inicial mínimo: $' || v_min::TEXT;
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

    INSERT INTO movimientos (usuario_id, tipo, monto, saldo_antes, saldo_despues,
                             descripcion, creado_en, procesado_en)
    VALUES (v_id, 'deposito', p_saldo_ini, 0, p_saldo_ini,
            'Saldo inicial al registrarse', NOW(), NOW());

    RETURN QUERY SELECT v_id, LOWER(p_username)::VARCHAR, p_alias::VARCHAR, NULL::TEXT;
END;
$$;
