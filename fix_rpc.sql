-- FIX: Drop function first because we are changing the return type signature
DROP FUNCTION IF EXISTS can_generate_image(uuid);

CREATE OR REPLACE FUNCTION can_generate_image(
  p_user_id UUID
)
RETURNS TABLE (
  can_generate BOOLEAN,
  reason TEXT,
  tier TEXT, -- Changed from VARCHAR(20) to TEXT
  tokens_available INTEGER,
  daily_remaining INTEGER,
  monthly_remaining INTEGER,
  uses_token BOOLEAN
) AS $$
DECLARE
  user_record telegram_users%ROWTYPE;
  free_daily_limit INTEGER;
  free_monthly_limit INTEGER;
BEGIN
  -- Get user data
  SELECT * INTO user_record FROM telegram_users WHERE id = p_user_id;
  
  -- Get limits from config
  SELECT daily_limit, monthly_limit INTO free_daily_limit, free_monthly_limit
  FROM pricing_config 
  WHERE config_type = 'tier' AND tier_name = 'free' AND is_active = true
  LIMIT 1;
  
  -- Default limits jika tidak ada config
  IF free_daily_limit IS NULL THEN free_daily_limit := 3; END IF;
  IF free_monthly_limit IS NULL THEN free_monthly_limit := 90; END IF;
  
  -- Reset counters jika diperlukan
  IF user_record.last_reset_date < CURRENT_DATE THEN
    UPDATE telegram_users 
    SET daily_images_generated = 0,
        last_reset_date = CURRENT_DATE
    WHERE id = p_user_id;
    user_record.daily_images_generated := 0;
  END IF;
  
  IF user_record.monthly_reset_date < DATE_TRUNC('month', CURRENT_DATE) THEN
    UPDATE telegram_users 
    SET monthly_images_generated = 0,
        monthly_reset_date = DATE_TRUNC('month', CURRENT_DATE)
    WHERE id = p_user_id;
    user_record.monthly_images_generated := 0;
  END IF;
  
  -- Check berdasarkan tier
  IF user_record.tier = 'free' THEN
    -- Free tier: cek daily & monthly limit
    RETURN QUERY
    SELECT 
      CASE 
        WHEN user_record.status != 'active' THEN false
        WHEN user_record.daily_images_generated >= free_daily_limit THEN false
        WHEN user_record.monthly_images_generated >= free_monthly_limit THEN false
        ELSE true
      END as can_generate,
      
      CASE 
        WHEN user_record.status != 'active' THEN 'Account is not active'
        WHEN user_record.daily_images_generated >= free_daily_limit 
          THEN 'Daily limit reached (' || user_record.daily_images_generated || '/' || free_daily_limit || ')'
        WHEN user_record.monthly_images_generated >= free_monthly_limit 
          THEN 'Monthly limit reached (' || user_record.monthly_images_generated || '/' || free_monthly_limit || ')'
        ELSE 'OK'
      END as reason,
      
      'free'::TEXT as tier,
      0 as tokens_available,
      GREATEST(0, free_daily_limit - user_record.daily_images_generated) as daily_remaining,
      GREATEST(0, free_monthly_limit - user_record.monthly_images_generated) as monthly_remaining,
      false as uses_token;
      
  ELSE -- paid tier
    -- Paid tier: cek token balance
    RETURN QUERY
    SELECT 
      CASE 
        WHEN user_record.status != 'active' THEN false
        WHEN user_record.token_balance < 1 THEN false
        ELSE true
      END as can_generate,
      
      CASE 
        WHEN user_record.status != 'active' THEN 'Account is not active'
        WHEN user_record.token_balance < 1 THEN 'Insufficient tokens. Please top up.'
        ELSE 'OK'
      END as reason,
      
      'paid'::TEXT as tier,
      user_record.token_balance as tokens_available,
      999 as daily_remaining, -- Unlimited
      999 as monthly_remaining, -- Unlimited
      true as uses_token;
  END IF;
END;
$$ LANGUAGE plpgsql;
