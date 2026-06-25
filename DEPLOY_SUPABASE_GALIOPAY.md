# Despliegue Supabase + GalioPay

1. Aplicar la migración SQL:
   `npx supabase db push --project-ref fvpywpfannhakqjsfoqq`

2. Configurar secretos de Edge Functions:
   `npx supabase secrets set GALIOPAY_CLIENT_ID=... GALIOPAY_API_KEY=... GALIOPAY_SANDBOX=false PUBLIC_SITE_URL=https://tu-dominio --project-ref fvpywpfannhakqjsfoqq`

3. Desplegar funciones:
   `npx supabase functions deploy galiopay-create-payment-link --project-ref fvpywpfannhakqjsfoqq`
   `npx supabase functions deploy galiopay-confirm-payment --project-ref fvpywpfannhakqjsfoqq`
   `npx supabase functions deploy galiopay-webhook --no-verify-jwt --project-ref fvpywpfannhakqjsfoqq`

4. En GalioPay, si usás webhook global, apuntarlo a:
   `https://fvpywpfannhakqjsfoqq.supabase.co/functions/v1/galiopay-webhook`

La app no acredita recargas hasta que GalioPay confirma el pago. Los retiros quedan registrados en Supabase como solicitud pendiente.
