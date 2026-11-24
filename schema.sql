-- ==========================================
-- AuditTrail Database Schema (Supabase + PostGIS)
-- ==========================================

-- 1. Enable PostGIS for geography/distance checks
CREATE EXTENSION IF NOT EXISTS postgis;

-- 2. Profiles (linked to Supabase auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  role TEXT NOT NULL CHECK (role IN ('worker', 'manager', 'client')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Automatically create a profile row when a user signs up via Supabase Auth
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, email, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    NEW.email,
    COALESCE(
      CASE
        WHEN NEW.raw_user_meta_data->>'role' IN ('worker', 'manager', 'client')
          THEN NEW.raw_user_meta_data->>'role'
        ELSE 'worker'
      END,
      'worker'
    )
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 3. Sites (with PostGIS geography point + geofence radius in meters)
CREATE TABLE IF NOT EXISTS public.sites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  address TEXT,
  -- Geography point (longitude, latitude in SRID 4326) for accurate meter distances
  location GEOGRAPHY(POINT, 4326) NOT NULL,
  radius_meters NUMERIC(10, 2) NOT NULL DEFAULT 100.00 CHECK (radius_meters > 0),
  created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sites_location ON public.sites USING GIST (location);

-- 4. Milestones (tracks deadlines, late penalties, weather-excused days, and approval status)
CREATE TABLE IF NOT EXISTS public.milestones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id UUID NOT NULL REFERENCES public.sites(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  due_date TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  penalty_per_day NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (penalty_per_day >= 0),
  excused_rain_days INTEGER NOT NULL DEFAULT 0 CHECK (excused_rain_days >= 0),
  calculated_penalty NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (calculated_penalty >= 0),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'submitted', 'approved', 'rejected')),
  reviewed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  reviewed_at TIMESTAMPTZ,
  review_notes TEXT,
  created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_milestones_site_id ON public.milestones(site_id);
CREATE INDEX IF NOT EXISTS idx_milestones_status ON public.milestones(status);

-- 5. Photos (stores storage path, capture GPS + distance check, file hash & pHash for duplicate detection)
CREATE TABLE IF NOT EXISTS public.photos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  milestone_id UUID NOT NULL REFERENCES public.milestones(id) ON DELETE CASCADE,
  uploaded_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL,
  captured_location GEOGRAPHY(POINT, 4326),
  distance_from_site_meters NUMERIC(10, 2),
  within_radius BOOLEAN NOT NULL DEFAULT FALSE,
  file_hash TEXT NOT NULL,
  phash TEXT NOT NULL,
  is_duplicate BOOLEAN NOT NULL DEFAULT FALSE,
  captured_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_photos_milestone_id ON public.photos(milestone_id);
CREATE INDEX IF NOT EXISTS idx_photos_uploaded_by ON public.photos(uploaded_by);
CREATE INDEX IF NOT EXISTS idx_photos_file_hash ON public.photos(file_hash);
CREATE INDEX IF NOT EXISTS idx_photos_phash ON public.photos(phash);

-- Keep updated_at fresh on updates
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_profiles_updated_at ON public.profiles;
CREATE TRIGGER set_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_sites_updated_at ON public.sites;
CREATE TRIGGER set_sites_updated_at
  BEFORE UPDATE ON public.sites
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_milestones_updated_at ON public.milestones;
CREATE TRIGGER set_milestones_updated_at
  BEFORE UPDATE ON public.milestones
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ==========================================
-- Row Level Security (RLS)
-- ==========================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.milestones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photos ENABLE ROW LEVEL SECURITY;

-- Helper function to read current user's role cleanly without recursion
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$$;

-- Profiles policies
CREATE POLICY "Users can view their own profile, managers/clients view all"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (
    id = auth.uid()
    OR public.current_user_role() IN ('manager', 'client')
  );

CREATE POLICY "Users can update their own profile"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- Sites policies
CREATE POLICY "Authenticated users can view sites"
  ON public.sites FOR SELECT
  TO authenticated
  USING (public.current_user_role() IN ('worker', 'manager', 'client'));

CREATE POLICY "Managers can insert sites"
  ON public.sites FOR INSERT
  TO authenticated
  WITH CHECK (public.current_user_role() = 'manager');

CREATE POLICY "Managers can update sites"
  ON public.sites FOR UPDATE
  TO authenticated
  USING (public.current_user_role() = 'manager')
  WITH CHECK (public.current_user_role() = 'manager');

-- Milestones policies
CREATE POLICY "Authenticated users can view milestones"
  ON public.milestones FOR SELECT
  TO authenticated
  USING (public.current_user_role() IN ('worker', 'manager', 'client'));

CREATE POLICY "Managers can create milestones"
  ON public.milestones FOR INSERT
  TO authenticated
  WITH CHECK (public.current_user_role() = 'manager');

CREATE POLICY "Workers and managers can update milestones"
  ON public.milestones FOR UPDATE
  TO authenticated
  USING (public.current_user_role() IN ('worker', 'manager'))
  WITH CHECK (public.current_user_role() IN ('worker', 'manager'));

-- Photos policies
CREATE POLICY "Authenticated users can view photos"
  ON public.photos FOR SELECT
  TO authenticated
  USING (public.current_user_role() IN ('worker', 'manager', 'client'));

CREATE POLICY "Workers and managers can upload photo records"
  ON public.photos FOR INSERT
  TO authenticated
  WITH CHECK (
    public.current_user_role() IN ('worker', 'manager')
    AND uploaded_by = auth.uid()
  );