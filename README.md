# CookBook: recetario interactivo

Aplicación móvil en Flutter para crear, organizar y consultar recetas. Funciona
**sin conexión** (SQLite es la fuente de verdad) y sincroniza los datos de cada
usuario con **Supabase** (PostgreSQL, Auth y Storage) cuando hay red.

## Funcionalidades

- Registro e inicio de sesión con correo y contraseña; cada usuario ve solo sus
  recetas.
- Crear, editar, marcar como favorita y eliminar recetas, aun sin conexión.
- Filtrar por categoría o por favoritas desde el menú lateral.
- Fotos desde la cámara o la galería, subidas a Supabase Storage.
- Dictado por voz de ingredientes e instrucciones.
- Lectura en voz alta de la receta.
- Sincronización automática al recuperar la red, al deslizar la lista hacia
  abajo o al tocar el ícono de estado de la barra superior.

## Requisitos

- [Flutter](https://docs.flutter.dev/get-started/install) con Dart `^3.13.4`
- Un proyecto de [Supabase](https://supabase.com).
- Un emulador o dispositivo físico (Android o iOS).

## Puesta en marcha

### 1. Configurar Supabase

1. Crea un proyecto en Supabase.
2. Abre el **SQL Editor** y ejecuta completo
   [`supabase/schema.sql`](supabase/schema.sql). El script crea las tablas,
   los permisos, las políticas de RLS, la función `upsert_recipe` y el bucket
   de fotos `recipe-images`. Se puede ejecutar más de una vez; si el proyecto
   ya tenía el esquema anterior de una sola tabla, migra los datos.
3. En **Project Settings → API** copia la URL del proyecto y la clave `anon`
   (o publicable).

### 2. Variables de entorno

Copia el ejemplo y llena los valores:

```bash
cp .env.example .env
```

```dotenv
SUPABASE_URL=https://tu-proyecto.supabase.co
SUPABASE_ANON_KEY=tu-clave-anon
```

`.env` está en `.gitignore`; no lo subas al repositorio. Los valores se leen al
compilar con `String.fromEnvironment`, así que no hay claves en el código.

### 3. Ejecutar

```bash
flutter pub get
```

```bash
flutter run --dart-define-from-file=.env
```

Si se compila sin las variables, la app muestra una pantalla con estas mismas
instrucciones en lugar de fallar.

## Arquitectura

```text
UI (screens/, widgets/)
   │  solo conoce RecipeRepository y AuthRepository (interfaces)
   ▼
LocalFirstRecipeRepository ──► DatabaseHelper (SQLite)   ← lecturas/escrituras inmediatas
   │
   └──► SyncService ──► SupabaseService ──► Supabase (Postgres, Auth, Storage)
            ▲
     connectivity_plus (sincroniza al volver la red)
```

- **Offline-first:** la UI siempre lee y escribe en SQLite. Cada cambio se marca
  `sync_status = 'pending'` y se sube en segundo plano.
- **Sincronización bidireccional** (`SyncService.syncAll`):
  1. *Pull:* descarga categorías y luego las recetas (con sus ingredientes)
     cambiadas desde el último cursor `server_updated_at`.
  2. Resuelve conflictos con **Last-Write-Wins** comparando `updated_at`.
  3. *Push:* sube fotos pendientes y guarda cada receta con la función remota
     `upsert_recipe`, que escribe receta e ingredientes en una transacción y
     rechaza versiones más antiguas que la del servidor.
- **IDs UUID v4** generados en el cliente, para crear recetas sin conexión sin
  colisiones entre dispositivos.
- **Borrado lógico** (`is_deleted`) para propagar eliminaciones a otros
  dispositivos.
- **Inyección de dependencias:** `main.dart` construye las implementaciones y
  las publica con `AppScope`; las pantallas aceptan dobles de prueba.

## Modelo de datos

Tres tablas, con la misma forma en SQLite y en Supabase:

```text
categories 1 ──< recipes 1 ──< ingredients
```

| Tabla         | Columnas principales                                                                 |
| ------------- | ------------------------------------------------------------------------------------ |
| `categories`  | `id`, `name`, `icon`, `sort_order`                                                   |
| `recipes`     | `id`, `user_id`, `title`, `category_id`, `prep_time`, `instructions`, `image_url`, `is_favorite`, `created_at`, `updated_at`, `is_deleted` |
| `ingredients` | `id`, `recipe_id`, `position`, `name` (+ `user_id` en Supabase)                      |

Columnas solo locales: `recipes.image_path` (foto en el dispositivo) y
`recipes.sync_status`. Solo en Supabase: `recipes.server_updated_at` (hora del
servidor, usada como cursor del pull). SQLite guarda además el cursor por
usuario en `sync_metadata`.

Las categorías son un catálogo compartido sembrado con cuatro valores
(Desayuno, Plato Fuerte, Postre, Bebida) con UUID fijos, iguales en
`lib/models/recipe_category.dart` y en `supabase/schema.sql`.

### Migraciones locales

La base `cookbook.db` está en la **versión 4**. Al abrir la app se migra
automáticamente, dentro de una transacción, desde cualquier versión anterior:

- **v1/v2** (ids enteros): cada receta recibe un UUID nuevo y queda sin dueño
  hasta que el primer usuario inicia sesión y la reclama.
- **v3** (una sola tabla): se conservan id, usuario y estado de
  sincronización; la categoría y los ingredientes pasan a sus tablas.

## Seguridad

- **RLS** en las tres tablas: cada usuario solo lee y modifica sus recetas e
  ingredientes; las categorías son de solo lectura para la app.
- Solo el rol `authenticated` tiene permisos sobre las tablas y la función.
- Las fotos se guardan en `recipe-images/<user_id>/<recipe_id>.jpg`; solo el
  dueño puede subirlas o reemplazarlas y la lectura es pública.

## Estructura del proyecto

```text
lib/
├── main.dart                 # Inicialización, AuthGate y rutas
├── app_scope.dart            # Inyección de dependencias (InheritedWidget)
├── config/                   # Lectura de SUPABASE_URL / SUPABASE_ANON_KEY
├── database/                 # SQLite, contrato RecipeRepository e implementación
├── models/                   # RecipeEntry, Ingredient, RecipeCategory, SyncState
├── screens/                  # Login, registro, lista, detalle y formulario
├── services/                 # Supabase, sincronización, cámara y voz
└── widgets/                  # Tarjeta, indicador de sync, íconos, dictado
supabase/
└── schema.sql                # Esquema remoto completo (idempotente)
test/                         # Pruebas de modelos, UI y migraciones de SQLite
```

## Pruebas y análisis

```bash
flutter analyze
```

```bash
flutter test
```

Las pruebas de migración usan `sqflite_common_ffi` para ejecutar SQLite real en
el equipo, sin emulador.

## Solución de problemas

| Síntoma | Causa y solución |
| ------- | ---------------- |
| Pantalla "Falta la configuración de Supabase" | Falta `.env` o no se pasó `--dart-define-from-file=.env`. |
| `permission denied for table …` | Faltan los `GRANT`; vuelve a ejecutar `supabase/schema.sql`. |
| `new row violates row-level security policy` | Faltan las políticas de RLS; vuelve a ejecutar `supabase/schema.sql`. |
| `Could not find the function public.upsert_recipe` | El script no se ejecutó completo en el proyecto. |
| El ícono de sync muestra pendientes sin conexión | Es lo esperado: se suben solos al volver la red. |

## Permisos del dispositivo

Cámara, galería, micrófono y reconocimiento de voz requieren permisos del
sistema operativo; la app los solicita al usar cada función. Internet se usa
solo para la autenticación y la sincronización con Supabase.
