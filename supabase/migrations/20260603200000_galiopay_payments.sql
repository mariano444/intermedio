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
