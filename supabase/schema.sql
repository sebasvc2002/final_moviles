-- =============================================================================
-- CookBook: esquema remoto de Supabase (tres tablas)
--
--   categories 1 ──< recipes 1 ──< ingredients
--
-- Este script es IDEMPOTENTE: sirve para un proyecto nuevo y también para
-- actualizar el proyecto que ya tiene la tabla `recipes` con las columnas de
-- texto `category` e `ingredients` (las convierte y luego las elimina).
-- Ejecútalo completo en el SQL Editor de Supabase.
--
-- Notas de diseño:
--   * server_updated_at: hora del SERVIDOR asignada por trigger. El pull
--     incremental la usa como cursor para no perder cambios hechos sin
--     conexión que se suben tarde. updated_at (hora del cliente) decide
--     Last-Write-Wins.
--   * La app escribe una receta y sus ingredientes con la función
--     upsert_recipe(), en una sola transacción.
-- =============================================================================

-- 1. Categorías (catálogo compartido, solo lectura para la app) -------------
CREATE TABLE IF NOT EXISTS public.categories (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  icon TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0
);

-- Los UUID deben coincidir con kDefaultCategories (lib/models/recipe_category.dart).
INSERT INTO public.categories (id, name, icon, sort_order) VALUES
  ('c0000000-0000-4000-8000-000000000001', 'Desayuno',     'breakfast', 1),
  ('c0000000-0000-4000-8000-000000000002', 'Plato Fuerte', 'main',      2),
  ('c0000000-0000-4000-8000-000000000003', 'Postre',       'dessert',   3),
  ('c0000000-0000-4000-8000-000000000004', 'Bebida',       'drink',     4)
ON CONFLICT (id) DO UPDATE
  SET name = EXCLUDED.name,
      icon = EXCLUDED.icon,
      sort_order = EXCLUDED.sort_order;

-- 2. Recetas -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.recipes (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  category_id UUID NOT NULL REFERENCES public.categories(id),
  prep_time TEXT NOT NULL DEFAULT '',
  instructions TEXT NOT NULL,
  image_url TEXT,
  is_favorite BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  server_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Columnas que faltan si la tabla se creó con versiones anteriores del script.
ALTER TABLE public.recipes ADD COLUMN IF NOT EXISTS prep_time TEXT NOT NULL DEFAULT '';
ALTER TABLE public.recipes ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE public.recipes ADD COLUMN IF NOT EXISTS server_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE public.recipes ADD COLUMN IF NOT EXISTS category_id UUID REFERENCES public.categories(id);

-- 3. Ingredientes --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ingredients (
  id UUID PRIMARY KEY,
  recipe_id UUID NOT NULL REFERENCES public.recipes(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  name TEXT NOT NULL
);

-- 4. Migración de datos desde el esquema de una sola tabla -------------------
DO $$
BEGIN
  -- category (texto) -> category_id (FK)
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'recipes'
      AND column_name = 'category'
  ) THEN
    UPDATE public.recipes r
       SET category_id = COALESCE(
             (SELECT c.id FROM public.categories c WHERE c.name = r.category),
             'c0000000-0000-4000-8000-000000000001'::uuid)
     WHERE r.category_id IS NULL;
    ALTER TABLE public.recipes DROP COLUMN category;
  END IF;

  -- ingredients (texto, uno por línea) -> filas de public.ingredients
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'recipes'
      AND column_name = 'ingredients'
  ) THEN
    INSERT INTO public.ingredients (id, recipe_id, user_id, position, name)
    SELECT gen_random_uuid(),
           r.id,
           r.user_id,
           (ROW_NUMBER() OVER (PARTITION BY r.id ORDER BY t.ord) - 1)::int,
           btrim(t.line)
      FROM public.recipes r
     CROSS JOIN LATERAL regexp_split_to_table(r.ingredients, E'\\r?\\n')
           WITH ORDINALITY AS t(line, ord)
     WHERE btrim(t.line) <> ''
       AND NOT EXISTS (
             SELECT 1 FROM public.ingredients i WHERE i.recipe_id = r.id);
    ALTER TABLE public.recipes DROP COLUMN ingredients;
  END IF;
END
$$;

ALTER TABLE public.recipes ALTER COLUMN category_id SET NOT NULL;

-- 5. Índices -------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_recipes_user_server_updated
  ON public.recipes (user_id, server_updated_at);
CREATE INDEX IF NOT EXISTS idx_recipes_category
  ON public.recipes (category_id);
CREATE INDEX IF NOT EXISTS idx_ingredients_recipe
  ON public.ingredients (recipe_id, position);
CREATE INDEX IF NOT EXISTS idx_ingredients_user
  ON public.ingredients (user_id);

-- 6. Trigger: el servidor sella cada inserción/actualización de recetas ------
CREATE OR REPLACE FUNCTION public.set_server_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.server_updated_at := clock_timestamp();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recipes_server_updated_at ON public.recipes;
CREATE TRIGGER trg_recipes_server_updated_at
  BEFORE INSERT OR UPDATE ON public.recipes
  FOR EACH ROW EXECUTE FUNCTION public.set_server_updated_at();

-- 7. Escritura atómica: receta + ingredientes con Last-Write-Wins ------------
-- Devuelve TRUE si se aplicó; FALSE si el servidor ya tenía una versión más
-- nueva (en ese caso no toca nada). Corre con los permisos del usuario
-- (SECURITY INVOKER), así que RLS sigue aplicando.
CREATE OR REPLACE FUNCTION public.upsert_recipe(p_recipe JSONB, p_ingredients JSONB)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_id UUID := (p_recipe->>'id')::uuid;
  v_applied BOOLEAN;
BEGIN
  IF auth.uid() IS NULL OR (p_recipe->>'user_id')::uuid IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'user_id no coincide con la sesión' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.recipes AS r (
    id, user_id, title, category_id, prep_time, instructions, image_url,
    is_favorite, created_at, updated_at, is_deleted
  ) VALUES (
    v_id,
    auth.uid(),
    p_recipe->>'title',
    (p_recipe->>'category_id')::uuid,
    COALESCE(p_recipe->>'prep_time', ''),
    p_recipe->>'instructions',
    p_recipe->>'image_url',
    COALESCE((p_recipe->>'is_favorite')::boolean, FALSE),
    COALESCE((p_recipe->>'created_at')::timestamptz, NOW()),
    (p_recipe->>'updated_at')::timestamptz,
    COALESCE((p_recipe->>'is_deleted')::boolean, FALSE)
  )
  ON CONFLICT (id) DO UPDATE SET
    title        = EXCLUDED.title,
    category_id  = EXCLUDED.category_id,
    prep_time    = EXCLUDED.prep_time,
    instructions = EXCLUDED.instructions,
    image_url    = EXCLUDED.image_url,
    is_favorite  = EXCLUDED.is_favorite,
    updated_at   = EXCLUDED.updated_at,
    is_deleted   = EXCLUDED.is_deleted
  WHERE r.updated_at <= EXCLUDED.updated_at
  RETURNING TRUE INTO v_applied;

  IF v_applied IS NULL THEN
    RETURN FALSE; -- el servidor tiene una versión más reciente
  END IF;

  DELETE FROM public.ingredients WHERE recipe_id = v_id;
  INSERT INTO public.ingredients (id, recipe_id, user_id, position, name)
  SELECT (i->>'id')::uuid, v_id, auth.uid(), (i->>'position')::int, i->>'name'
    FROM jsonb_array_elements(COALESCE(p_ingredients, '[]'::jsonb)) AS i;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_recipe(JSONB, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_recipe(JSONB, JSONB) TO authenticated;

-- 8. Permisos de tabla -----------------------------------------------------------
-- Los proyectos nuevos no otorgan permisos automáticamente a tablas creadas
-- por SQL ("permission denied for table ..."). Solo el rol `authenticated`;
-- RLS limita después cada fila a su dueño. Las recetas no se borran
-- físicamente (borrado lógico), los ingredientes sí se reemplazan.
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON public.categories TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.recipes TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.ingredients TO authenticated;

-- 9. Row-Level Security ----------------------------------------------------------
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ingredients ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated users can read categories" ON public.categories;
CREATE POLICY "Authenticated users can read categories"
  ON public.categories FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Users can select own recipes" ON public.recipes;
CREATE POLICY "Users can select own recipes"
  ON public.recipes FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own recipes" ON public.recipes;
CREATE POLICY "Users can insert own recipes"
  ON public.recipes FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own recipes" ON public.recipes;
CREATE POLICY "Users can update own recipes"
  ON public.recipes FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can select own ingredients" ON public.ingredients;
CREATE POLICY "Users can select own ingredients"
  ON public.ingredients FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own ingredients" ON public.ingredients;
CREATE POLICY "Users can insert own ingredients"
  ON public.ingredients FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.recipes r
      WHERE r.id = recipe_id AND r.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Users can delete own ingredients" ON public.ingredients;
CREATE POLICY "Users can delete own ingredients"
  ON public.ingredients FOR DELETE
  USING (auth.uid() = user_id);

-- 10. Bucket de fotos ----------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('recipe-images', 'recipe-images', true)
ON CONFLICT (id) DO NOTHING;

-- Políticas de Storage (ruta: <user_id>/<recipe_id>.jpg)
DROP POLICY IF EXISTS "Users can upload own recipe images" ON storage.objects;
CREATE POLICY "Users can upload own recipe images"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'recipe-images'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

DROP POLICY IF EXISTS "Users can update own recipe images" ON storage.objects;
CREATE POLICY "Users can update own recipe images"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'recipe-images'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- upsert:true en Storage también necesita SELECT sobre el objeto existente.
DROP POLICY IF EXISTS "Public read access for recipe images" ON storage.objects;
CREATE POLICY "Public read access for recipe images"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'recipe-images');
