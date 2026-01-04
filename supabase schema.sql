-- 1. Table utama untuk user Telegram
CREATE TABLE telegram_users (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  chat_id BIGINT UNIQUE NOT NULL,
  username VARCHAR(255),
  first_name VARCHAR(255),
  last_name VARCHAR(255),
  language_code VARCHAR(10),
  is_bot BOOLEAN DEFAULT false,
  is_premium BOOLEAN DEFAULT false,
  
  -- Hanya 2 tier: free atau paid
  tier VARCHAR(20) DEFAULT 'free' CHECK (tier IN ('free', 'paid')),
  status VARCHAR(50) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'banned', 'suspended')),
  
  -- Token/balance system (hanya digunakan untuk paid tier)
  token_balance INTEGER DEFAULT 0,
  total_tokens_purchased INTEGER DEFAULT 0,
  total_tokens_used INTEGER DEFAULT 0,
  total_images_generated INTEGER DEFAULT 0,
  
  -- Batasan untuk free tier
  daily_images_generated INTEGER DEFAULT 0,
  monthly_images_generated INTEGER DEFAULT 0,
  last_reset_date DATE DEFAULT CURRENT_DATE,
  monthly_reset_date DATE DEFAULT DATE_TRUNC('month', CURRENT_DATE),
  
  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  last_active TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  subscribed_at TIMESTAMP WITH TIME ZONE,
  subscription_ends_at TIMESTAMP WITH TIME ZONE
);

-- 2. Table untuk transaksi token (topup)
CREATE TABLE token_transactions (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES telegram_users(id) ON DELETE CASCADE,
  transaction_type VARCHAR(50) CHECK (transaction_type IN ('topup', 'usage', 'bonus', 'refund', 'subscription')),
  amount INTEGER NOT NULL,
  price_paid DECIMAL(10, 2), -- Harga dalam Rupiah/USD
  currency VARCHAR(3) DEFAULT 'IDR',
  
  -- Untuk topup
  payment_method VARCHAR(50),
  payment_status VARCHAR(50) DEFAULT 'pending' CHECK (payment_status IN ('pending', 'completed', 'failed', 'refunded')),
  payment_reference VARCHAR(255),
  payment_provider VARCHAR(50),
  
  description TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. Table untuk riwayat generate image
CREATE TABLE image_generation_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES telegram_users(id) ON DELETE CASCADE,
  chat_id BIGINT NOT NULL,
  tier_used VARCHAR(20) DEFAULT 'free',
  prompt TEXT NOT NULL,
  prompt_hash VARCHAR(64),
  model_used VARCHAR(100) DEFAULT 'zimage',
  image_size VARCHAR(20) DEFAULT '1024x1280',
  seed INTEGER,
  tokens_used INTEGER DEFAULT 0, -- 0 untuk free, 1 untuk paid
  generation_time_ms INTEGER,
  success BOOLEAN DEFAULT true,
  error_message TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. Table untuk konfigurasi pricing
CREATE TABLE pricing_config (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  config_name VARCHAR(100) UNIQUE NOT NULL,
  config_type VARCHAR(50) CHECK (config_type IN ('tier', 'token_package', 'subscription')),
  
  -- Untuk tier configuration
  tier_name VARCHAR(20),
  daily_limit INTEGER,
  monthly_limit INTEGER,
  max_image_size VARCHAR(20),
  available_models TEXT[] DEFAULT '{"zimage"}',
  
  -- Untuk token packages
  token_amount INTEGER,
  token_price DECIMAL(10, 2),
  currency VARCHAR(3) DEFAULT 'IDR',
  bonus_tokens INTEGER DEFAULT 0,
  
  -- Untuk subscription
  subscription_days INTEGER,
  subscription_price DECIMAL(10, 2),
  subscription_tokens INTEGER, -- Token bulanan
  
  is_active BOOLEAN DEFAULT true,
  display_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. Table untuk packages token yang dijual
CREATE TABLE token_packages (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  package_name VARCHAR(100) NOT NULL,
  token_amount INTEGER NOT NULL,
  price DECIMAL(10, 2) NOT NULL,
  currency VARCHAR(3) DEFAULT 'IDR',
  bonus_tokens INTEGER DEFAULT 0,
  is_popular BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  display_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 6. Index untuk performa
CREATE INDEX idx_telegram_users_chat_id ON telegram_users(chat_id);
CREATE INDEX idx_telegram_users_tier ON telegram_users(tier);
CREATE INDEX idx_telegram_users_status ON telegram_users(status);
CREATE INDEX idx_telegram_users_token_balance ON telegram_users(token_balance) WHERE tier = 'paid';
CREATE INDEX idx_telegram_users_last_reset ON telegram_users(last_reset_date);
CREATE INDEX idx_telegram_users_monthly_reset ON telegram_users(monthly_reset_date);

CREATE INDEX idx_token_transactions_user_id ON token_transactions(user_id);
CREATE INDEX idx_token_transactions_payment_status ON token_transactions(payment_status);
CREATE INDEX idx_token_transactions_created_at ON token_transactions(created_at);

CREATE INDEX idx_image_logs_user_id ON image_generation_logs(user_id);
CREATE INDEX idx_image_logs_created_at ON image_generation_logs(created_at);
CREATE INDEX idx_image_logs_tier_used ON image_generation_logs(tier_used);

CREATE INDEX idx_token_packages_is_active ON token_packages(is_active);
CREATE INDEX idx_token_packages_display_order ON token_packages(display_order);

-- 7. Function untuk reset counters harian/bulanan
CREATE OR REPLACE FUNCTION reset_user_counters()
RETURNS void AS $$
BEGIN
  -- Reset daily counters
  UPDATE telegram_users 
  SET daily_images_generated = 0,
      last_reset_date = CURRENT_DATE
  WHERE last_reset_date < CURRENT_DATE;
  
  -- Reset monthly counters (setiap tanggal 1)
  UPDATE telegram_users 
  SET monthly_images_generated = 0,
      monthly_reset_date = DATE_TRUNC('month', CURRENT_DATE)
  WHERE monthly_reset_date < DATE_TRUNC('month', CURRENT_DATE);
END;
$$ LANGUAGE plpgsql;

-- 8. Function untuk mengecek apakah user bisa generate image
CREATE OR REPLACE FUNCTION can_generate_image(
  p_user_id UUID
)
RETURNS TABLE (
  can_generate BOOLEAN,
  reason TEXT,
  tier VARCHAR(20),
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
      
      'free' as tier,
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
      
      'paid' as tier,
      user_record.token_balance as tokens_available,
      999 as daily_remaining, -- Unlimited
      999 as monthly_remaining, -- Unlimited
      true as uses_token;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 9. Function untuk topup token
CREATE OR REPLACE FUNCTION topup_tokens(
  p_user_id UUID,
  p_package_id UUID,
  p_payment_method VARCHAR(50),
  p_payment_reference VARCHAR(255),
  p_payment_provider VARCHAR(50)
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  new_balance INTEGER
) AS $$
DECLARE
  package_record token_packages%ROWTYPE;
  user_tier VARCHAR(20);
BEGIN
  -- Get package details
  SELECT * INTO package_record FROM token_packages 
  WHERE id = p_package_id AND is_active = true;
  
  IF package_record.id IS NULL THEN
    RETURN QUERY SELECT false, 'Token package not found or inactive', 0;
    RETURN;
  END IF;
  
  -- Get user tier
  SELECT tier INTO user_tier FROM telegram_users WHERE id = p_user_id;
  
  -- If user is free tier, upgrade to paid
  IF user_tier = 'free' THEN
    UPDATE telegram_users 
    SET tier = 'paid',
        updated_at = NOW()
    WHERE id = p_user_id;
  END IF;
  
  -- Update user token balance
  UPDATE telegram_users 
  SET 
    token_balance = token_balance + package_record.token_amount + package_record.bonus_tokens,
    total_tokens_purchased = total_tokens_purchased + package_record.token_amount + package_record.bonus_tokens,
    updated_at = NOW()
  WHERE id = p_user_id
  RETURNING token_balance INTO new_balance;
  
  -- Log transaction
  INSERT INTO token_transactions (
    user_id,
    transaction_type,
    amount,
    price_paid,
    currency,
    payment_method,
    payment_reference,
    payment_provider,
    payment_status,
    description
  ) VALUES (
    p_user_id,
    'topup',
    package_record.token_amount + package_record.bonus_tokens,
    package_record.price,
    package_record.currency,
    p_payment_method,
    p_payment_reference,
    p_payment_provider,
    'completed',
    'Purchased ' || package_record.package_name || 
    CASE WHEN package_record.bonus_tokens > 0 
      THEN ' (+' || package_record.bonus_tokens || ' bonus)' 
      ELSE '' 
    END
  );
  
  RETURN QUERY SELECT true, 'Topup successful', new_balance;
END;
$$ LANGUAGE plpgsql;

-- 10. Function untuk proses generate image
CREATE OR REPLACE FUNCTION process_image_generation(
  p_user_id UUID,
  p_chat_id BIGINT,
  p_prompt TEXT,
  p_model_used VARCHAR(100) DEFAULT 'zimage',
  p_image_size VARCHAR(20) DEFAULT '1024x1280',
  p_seed INTEGER DEFAULT NULL,
  p_generation_time_ms INTEGER DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  can_proceed BOOLEAN,
  tier_used VARCHAR(20),
  tokens_used INTEGER,
  tokens_remaining INTEGER
) AS $$
DECLARE
  can_generate_result RECORD;
  user_tier VARCHAR(20);
  tokens_to_use INTEGER;
BEGIN
  -- Check if user can generate
  SELECT * INTO can_generate_result FROM can_generate_image(p_user_id);
  
  IF NOT can_generate_result.can_generate THEN
    RETURN QUERY SELECT false, can_generate_result.reason, false, NULL, 0, 0;
    RETURN;
  END IF;
  
  -- Determine tier and tokens to use
  user_tier := can_generate_result.tier;
  tokens_to_use := CASE WHEN user_tier = 'paid' THEN 1 ELSE 0 END;
  
  -- Update user stats berdasarkan tier
  IF user_tier = 'free' THEN
    UPDATE telegram_users 
    SET 
      total_images_generated = total_images_generated + 1,
      daily_images_generated = daily_images_generated + 1,
      monthly_images_generated = monthly_images_generated + 1,
      updated_at = NOW()
    WHERE id = p_user_id;
  ELSE -- paid tier
    UPDATE telegram_users 
    SET 
      total_images_generated = total_images_generated + 1,
      token_balance = token_balance - 1,
      total_tokens_used = total_tokens_used + 1,
      updated_at = NOW()
    WHERE id = p_user_id;
    
    -- Log token usage
    INSERT INTO token_transactions (
      user_id,
      transaction_type,
      amount,
      description
    ) VALUES (
      p_user_id,
      'usage',
      -1,
      'Image generation: ' || LEFT(p_prompt, 50)
    );
  END IF;
  
  -- Log image generation
  INSERT INTO image_generation_logs (
    user_id,
    chat_id,
    tier_used,
    prompt,
    model_used,
    image_size,
    seed,
    tokens_used,
    generation_time_ms
  ) VALUES (
    p_user_id,
    p_chat_id,
    user_tier,
    p_prompt,
    p_model_used,
    p_image_size,
    p_seed,
    tokens_to_use,
    p_generation_time_ms
  );
  
  -- Get remaining tokens/limits
  IF user_tier = 'free' THEN
    tokens_remaining := 0;
  ELSE
    SELECT token_balance INTO tokens_remaining 
    FROM telegram_users WHERE id = p_user_id;
  END IF;
  
  RETURN QUERY SELECT true, 'Image generation logged', true, user_tier, tokens_to_use, tokens_remaining;
END;
$$ LANGUAGE plpgsql;

-- 11. Function untuk upgrade ke paid tier
CREATE OR REPLACE FUNCTION upgrade_to_paid(
  p_user_id UUID
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
) AS $$
DECLARE
  current_tier VARCHAR(20);
BEGIN
  SELECT tier INTO current_tier FROM telegram_users WHERE id = p_user_id;
  
  IF current_tier = 'paid' THEN
    RETURN QUERY SELECT false, 'User is already on paid tier';
    RETURN;
  END IF;
  
  UPDATE telegram_users 
  SET 
    tier = 'paid',
    subscribed_at = NOW(),
    updated_at = NOW()
  WHERE id = p_user_id;
  
  -- Log subscription
  INSERT INTO token_transactions (
    user_id,
    transaction_type,
    amount,
    description,
    payment_status
  ) VALUES (
    p_user_id,
    'subscription',
    0,
    'Upgraded to paid tier',
    'completed'
  );
  
  RETURN QUERY SELECT true, 'Successfully upgraded to paid tier';
END;
$$ LANGUAGE plpgsql;

-- 12. Trigger untuk update timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_telegram_users_updated_at
BEFORE UPDATE ON telegram_users
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pricing_config_updated_at
BEFORE UPDATE ON pricing_config
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 13. Insert default configuration
-- Free tier config
INSERT INTO pricing_config (config_name, config_type, tier_name, daily_limit, monthly_limit, max_image_size) VALUES
('free_tier', 'tier', 'free', 3, 90, '1024x1280')
ON CONFLICT (config_name) DO NOTHING;

-- Token packages (contoh: 10K = 100 token)
INSERT INTO token_packages (package_name, token_amount, price, bonus_tokens, is_popular, display_order) VALUES
('Starter Pack', 50, 5000, 5, false, 1),
('Basic Pack', 100, 10000, 10, true, 2),
('Pro Pack', 250, 25000, 25, false, 3),
('Ultimate Pack', 500, 50000, 50, false, 4),
('Mega Pack', 1000, 100000, 100, false, 5)
ON CONFLICT DO NOTHING;

-- 14. Enable RLS
ALTER TABLE telegram_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE token_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE image_generation_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE pricing_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE token_packages ENABLE ROW LEVEL SECURITY;

-- 15. Create policies (hanya service role yang bisa akses semua)
CREATE POLICY "Service role full access" ON telegram_users
  FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

CREATE POLICY "Service role full access" ON token_transactions
  FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

CREATE POLICY "Service role full access" ON image_generation_logs
  FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

CREATE POLICY "Service role full access" ON pricing_config
  FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

CREATE POLICY "Service role full access" ON token_packages
  FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

-- 16. View untuk dashboard
CREATE OR REPLACE VIEW dashboard_stats AS
SELECT 
  (SELECT COUNT(*) FROM telegram_users) as total_users,
  (SELECT COUNT(*) FROM telegram_users WHERE tier = 'paid') as paid_users,
  (SELECT COUNT(*) FROM telegram_users WHERE tier = 'free') as free_users,
  (SELECT SUM(token_balance) FROM telegram_users WHERE tier = 'paid') as total_tokens_in_circulation,
  (SELECT SUM(price_paid) FROM token_transactions WHERE payment_status = 'completed' AND transaction_type = 'topup') as total_revenue,
  (SELECT COUNT(*) FROM image_generation_logs WHERE created_at >= CURRENT_DATE) as today_generations,
  (SELECT COUNT(*) FROM image_generation_logs WHERE tier_used = 'paid') as paid_generations,
  (SELECT COUNT(*) FROM image_generation_logs WHERE tier_used = 'free') as free_generations;

-- 17. Function untuk upsert user (digunakan di n8n)
CREATE OR REPLACE FUNCTION upsert_telegram_user(
  p_chat_id BIGINT,
  p_username VARCHAR(255) DEFAULT NULL,
  p_first_name VARCHAR(255) DEFAULT NULL,
  p_last_name VARCHAR(255) DEFAULT NULL,
  p_language_code VARCHAR(10) DEFAULT NULL,
  p_is_bot BOOLEAN DEFAULT false
)
RETURNS SETOF telegram_users AS $$
BEGIN
  RETURN QUERY
  INSERT INTO telegram_users (
    chat_id,
    username,
    first_name,
    last_name,
    language_code,
    is_bot,
    last_active
  ) VALUES (
    p_chat_id,
    p_username,
    p_first_name,
    p_last_name,
    p_language_code,
    p_is_bot,
    NOW()
  )
  ON CONFLICT (chat_id) 
  DO UPDATE SET
    username = EXCLUDED.username,
    first_name = EXCLUDED.first_name,
    last_name = EXCLUDED.last_name,
    language_code = EXCLUDED.language_code,
    last_active = NOW(),
    updated_at = NOW()
  RETURNING *;
END;
$$ LANGUAGE plpgsql;