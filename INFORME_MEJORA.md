# Informe de mejora del framework Malla

## 1. Introducción y alcance

Este informe consolida los hallazgos del análisis de mejora del framework Malla, un framework para servicios distribuidos en Elixir basado en plugins con encadenamiento de callbacks resuelto en tiempo de compilación. Se analizó el código fuente bajo `lib/` (aproximadamente 7180 líneas de código), el conjunto de guías (`guides/`) y el fichero `AGENTS.md`. La metodología empleó un análisis multi-agente seguido de una verificación adversarial de cada hallazgo, en la que se contrastó la afirmación contra el código real, se reevaluó la severidad y se confirmó (o descartó) la evidencia. Solo se incluyen aquí los hallazgos verificados y deduplicados.

## 2. Resumen por categoría y severidad

| Categoría | Crítica | Alta | Media | Baja | Total |
|---|---|---|---|---|---|
| Bugs | 0 | 3 | 4 | 0 | 7 |
| Inconsistencias con la documentación | 0 | 4 | 2 | 5 | 11 |
| Propuestas de mejora | 0 | 0 | 1 | 2 | 3 |
| **Total** | **0** | **7** | **7** | **7** | **21** |

Nota: el problema del orden de dependencias en grupos de plugins aparecía duplicado en los hallazgos originales (una entrada como bug de severidad media y otra como inconsistencia de comentario de severidad alta). Se han fusionado y tratado de forma unificada en la sección de inconsistencias, ya que la verificación concluyó que el comportamiento final es correcto y el defecto reside en la documentación/comentario.

## 3. Bugs

### 3.1 [Alta] El resultado de los callbacks `plugin_updated` se ignora silenciosamente al reconfigurar

- **Ubicación:** `lib/malla/service/server.ex:224-225`
- **Problema:** Al reconfigurar un servicio mediante `Malla.Service.reconfigure/2`, el resultado de `call_plugin_updated` se descarta usando `_result`. Si algún plugin devuelve `{:error, error}` desde su callback `plugin_updated`, ese error nunca se propaga al llamante, que recibe `:ok` en su lugar.
- **Evidencia:** La línea 224 ejecuta `_result = call_plugin_updated(chain, old_config, service)` y la 225 retorna incondicionalmente `{:reply, :ok, state}`. La función `call_plugin_updated` puede devolver `{:error, error}` (línea 570). El handler de `add_plugin` (`lib/malla/service/server.ex:255-256`) sí comprueba y propaga los errores correctamente, lo que confirma que esto es un descuido.
- **Corrección sugerida:** Capturar el resultado y hacer pattern matching:
  ```elixir
  result = call_plugin_updated(chain, old_config, service)
  case result do
    {:ok} -> {:reply, :ok, state}
    {:error, error} -> {:reply, {:error, error}, state}
  end
  ```
  La supresión silenciosa de errores en el handler de configuración puede dejar el servicio en un estado inconsistente sin que el operador lo sepa.

### 3.2 [Alta] El matching de respuestas del servidor carece de cláusula catch-all y provoca crashes

- **Ubicación:** `lib/malla/plugins/request.ex:180-198`
- **Problema:** El callback de servidor `malla_request` usa un `case` para discriminar el tipo de respuesta, pero no tiene cláusula catch-all. Si un handler devuelve `{result, data}` con `result` igual a `:ok` o `:created` y `data` que no es ni mapa ni lista (por ejemplo `{:ok, 123}`), el pattern de la línea 185 falla y se levanta `FunctionClauseError` en lugar de manejarse de forma controlada.
- **Evidencia:** La cláusula `{result, data} when result in [:ok, :created] and (is_map(data) or is_list(data))` no va seguida de ninguna cláusula que cubra el caso de `data` primitivo. En el código existen handlers como `regular_function/2` que devuelven `{:ok, a+b}` (ver `call_test_service.ex:16`), y la documentación (`guides/08-distribution/04-request-handling.md:101`) afirma explícitamente que `data` puede ser "maps, lists, primitives", contradiciendo la restricción del código.
- **Corrección sugerida:** Añadir una cláusula catch-all que trate los datos no-mapa/no-lista bien como error, bien envolviéndolos, o validar con un mensaje de error claro antes del `case`.

### 3.3 [Alta] El manejo de respuestas en cliente no valida el tipo de dato (comportamiento asimétrico con el servidor)

- **Ubicación:** `lib/malla/request.ex:220-223`
- **Problema:** La función cliente `request/4` hace match de `{result, data}` para `:ok` y `:created` sin validar que `data` sea mapa o lista, a diferencia del servidor (`lib/malla/plugins/request.ex:185`) que sí incluye el guard `is_map/is_list`. Esta asimetría implica que el cliente acepta y deja pasar cualquier tipo de respuesta, mientras que el servidor puede crashear ante la misma respuesta inválida.
- **Evidencia:** La línea 220 contiene `{result, data} when result in [:ok, :created] ->` sin guard de tipo. El protocolo documentado (líneas 73-82 del módulo) exige que `data` sea "map o list", por lo que la implementación cliente es no conforme. Esto crea inconsistencia distribuida: la misma respuesta inválida se maneja de forma distinta en cada lado, pudiendo enmascarar bugs en las implementaciones de servicios.
- **Corrección sugerida:** Unificar el contrato: o bien añadir el mismo guard `is_map/is_list` en el match del cliente (línea 220), o bien retirarlo del servidor para aceptar cualquier tipo de dato. El protocolo documentado debe coincidir con la implementación en ambos extremos. Conviene resolver este hallazgo junto con 3.2 para mantener la coherencia del protocolo.

### 3.4 [Media] Se usa merge superficial en lugar de merge profundo en la ruta de fusión de configuración

- **Ubicación:** `lib/malla/service/server.ex:514`
- **Problema:** La implementación por defecto de fusión de configuración usa `Keyword.merge()`, que realiza un merge superficial, pero la documentación y los comentarios afirman que se hace "deep-merge by default". Las listas de keywords anidadas se reemplazan por completo en lugar de fusionarse recursivamente.
- **Evidencia:** La línea 514 contiene `{:ok, Keyword.merge(config, update)}` con el comentario "No plugins handled merge, deep-merge by default". Esto contradice `guides/07-configuration.md:22` ("Configuration is deep-merged from several sources"). Existe la utilidad `Malla.Util.keyword_merge()` (`lib/malla/util.ex:95-96`) con la implementación correcta de merge recursivo, pero no se usa. Impacto práctico: si una config tiene `plugin_config: [a: 1, b: 2]` y se reconfigura con `plugin_config: [a: 10]`, la clave `:plugin_config` entera se reemplaza por `[a: 10]`, perdiéndose `b: 2`.
- **Corrección sugerida:** Sustituir `Keyword.merge(config, update)` por `Malla.Util.keyword_merge(config, update)` en la línea 514 y actualizar el comentario. La severidad es media porque esta ruta solo se activa cuando ningún plugin implementa `plugin_config_merge` (los servicios probados con config anidada lo implementan manualmente) y el efecto es pérdida de configuración, no un crash.

### 3.5 [Media] Tipo incorrecto en la metadata de Event: `first_timestamp` se almacena como `NaiveDateTime` pero el spec declara `DateTime`

- **Ubicación:** `lib/malla/event.ex:43` (type spec) y `lib/malla/event.ex:169` (implementación)
- **Problema:** El `@type` de la línea 43 declara `first_timestamp` como `DateTime.t()`, pero `update_counter/1` almacena directamente `timestamp` (que es `NaiveDateTime.t()`, definido en la línea 35) en la metadata en las líneas 169 y 183. Esto viola el contrato de tipo documentado y puede causar problemas en código que espere valores `DateTime` con información de zona horaria.
- **Evidencia:** El código convierte el timestamp a `DateTime` en la línea 154 (`datetime = DateTime.from_naive!(timestamp, "Etc/UTC")`), pero en la línea 169 almacena el `timestamp` sin convertir en lugar del `datetime` convertido. En la línea 183 sí se almacena el `first_timestamp` recuperado de ETS (que ya contiene el `DateTime` convertido), por lo que el bug solo se manifiesta en la primera ocurrencia de un hash de evento duplicado.
- **Corrección sugerida:** Convertir el timestamp antes de almacenarlo (`first_timestamp: DateTime.from_naive!(timestamp, "Etc/UTC")` en las líneas 169 y 183), o bien actualizar el spec a `NaiveDateTime.t()` si la información de zona horaria no es necesaria.

### 3.6 [Media] Spec de tipo incorrecto para el parámetro de callback de `Config.update/3`

- **Ubicación:** `lib/malla/config.ex:84`
- **Problema:** El `@spec` de `update/3` declara el parámetro de callback como `(domain() -> term())` cuando debería ser `(term() -> term())`. La función aplica el callback al valor almacenado actual (que es `term()`), no a un identificador de dominio.
- **Evidencia:** La línea 84 declara `@spec update(domain(), term(), (domain() -> term())) :: :ok`, pero las líneas 109-112 muestran que el callback se aplica al valor almacenado: `new = fun.(old)` donde `old = get(domain, key)` (que es `term()`, no `domain()`). `get/3` retorna `term()` según su documentación (línea 52). Este error provocaría que Dialyzer marque incorrectamente usos válidos.
- **Corrección sugerida:** Cambiar el `@spec` de la línea 84 a `@spec update(domain(), term(), (term() -> term())) :: :ok`.

### 3.7 [Media] El tipo `call_result` es incompleto y engañoso

- **Ubicación:** `lib/malla/node.ex:152-153`
- **Problema:** El spec `call_result` solo documenta los errores de `Malla.Node.call/4`, pero se usa como tipo de retorno de `call_cb/4`, que envuelve los errores a través de `Malla.remote/4`, resultando en estructuras de error distintas a las indicadas por el tipo.
- **Evidencia:** La definición de tipo en las líneas 152-153 no incluye `{:malla_rpc_error, ...}`, que es lo que `Malla.remote` realmente devuelve tras la transformación de la línea 340 (`lib/malla.ex`). El único llamante de `call_cb/4` es `Malla.remote/4`, que transforma `{:error, {:malla_rpc, ...}}` en `{:error, {:malla_rpc_error, ...}}`.
- **Corrección sugerida:** Crear specs distintos para cada ruta de retorno: mantener `call_result` para `Malla.Node.call/4`, y crear un `remote_call_result` para `Malla.remote/4` que incluya `{:malla_rpc_error, {term(), String.t()}}`.

## 4. Inconsistencias con la documentación

### 4.1 [Alta] La documentación muestra un valor de retorno incorrecto para solicitar reinicio en `plugin_updated`

- **Ubicación:** `guides/07a-reconfiguration.md:67` vs `lib/malla/service/server.ex:566` y `lib/malla/plugin.ex:110-115`
- **Problema:** La guía de reconfiguración muestra `{:restart, :configuration_changed}` como valor de retorno para solicitar el reinicio de un servicio en callbacks `plugin_updated`. Sin embargo, la especificación del callback define el tipo de retorno como `:ok | {:ok, [updated_opts]} | {:error, term()}`, y la implementación comprueba `{:ok, restart: true}` dentro de la lista de opts.
- **Evidencia:** La línea 67 de la guía muestra `{:restart, :configuration_changed}`, pero `server.ex:566` evalúa `if opts[:restart]`, lo que requiere que `restart` esté en la keyword list de opts y no como elemento de tupla. El código de test (`test/support/plugin2_1.ex:111`) y el segundo ejemplo de la propia guía (línea 124) usan correctamente `{:ok, restart: true}`. Seguir el ejemplo incorrecto haría fallar el pattern matching y el reinicio no se dispararía.
- **Corrección sugerida:** Actualizar `guides/07a-reconfiguration.md:67` de `{:restart, :configuration_changed}` a `{:ok, restart: true}`.

### 4.2 [Alta] Anotación de tipo incorrecta para el campo `callbacks` de `Service.t`

- **Ubicación:** `lib/malla/service.ex:72` vs `lib/malla/service/make.ex:277,306-307`
- **Problema:** La anotación `@type t` para el campo `callbacks` afirma que la estructura es `%{{atom, integer} => {atom, [module()]}}`, pero la estructura real almacenada por `do_add_callbacks` es una lista de tuplas `{module, function_name}`, no una única tupla con un nombre de función y una lista de módulos.
- **Evidencia:** La definición de tipo (línea 72) declara un mapa. Sin embargo, el código en `make.ex:277` devuelve `Map.to_list(acc)` (convirtiendo el mapa en lista de tuplas) y cada valor es `[{plugin, real_name} | plugins]` (líneas 306-307), es decir, una lista de tuplas `{module, atom}`. El código funciona correctamente pese a la anotación errónea; el impacto es sobre type checkers y desarrolladores.
- **Corrección sugerida:** Cambiar la anotación a `callbacks: %{{atom, integer} => [{module, atom}, ...]}`, o mejor definir un tipo dedicado: `@type callback_entry :: {module, atom}` y usar `callbacks: %{{atom, integer} => [callback_entry]}`.

### 4.3 [Alta] El comentario sobre el orden de dependencias de grupos contradice la implementación (orden invertido en grupos de plugins)

- **Ubicación:** `lib/malla/service/make.ex:106-110` y `lib/malla/service/make.ex:113-151`
- **Problema:** El comentario que describe cómo funcionan los grupos de plugins contradice el comportamiento real del código. El comentario afirma "PluginB will depend on PluginA and PluginC will depend on PluginB", pero la lógica de `add_group_deps`, debido al `Enum.reverse` de la línea 113, implementa el orden opuesto: `PluginB` depende de `PluginC` y `PluginA` depende de `PluginB`.
- **Evidencia:** La línea 113 invierte la lista de plugins. Trazando la ejecución para `[PluginA, PluginB, PluginC]`: la lista pasa a `[PluginC, PluginB, PluginA]`, y se generan las dependencias `A→B` y `B→C`. **Punto clave:** debido a inversiones posteriores (ordenación topológica en línea 85, inversión del resultado en línea 99 y nueva inversión en `get_callbacks` línea 272), el **orden de ejecución final de los callbacks resulta correcto** (`C → B → A` para `[A, B, C]`), coincidiendo con la guía `guides/04-plugins.md:114-127`. Por tanto, el defecto es de claridad/documentación en el comentario inline, no un bug funcional. No obstante, **no existen tests que verifiquen esta funcionalidad**, lo que hace el código frágil.
- **Corrección sugerida:** Actualizar el comentario de las líneas 106-110 para que refleje la implementación real, o refactorizar `add_group_deps` para eliminar el `Enum.reverse` redundante de la línea 113 (la corrección hace que el procesamiento en orden directo produzca `B→A` y `C→B`, coincidiendo con el comentario actual). En cualquier caso, **añadir tests** que fijen el orden de ejecución esperado. Nota: este hallazgo unifica las dos entradas duplicadas del análisis original (bug medio + inconsistencia alta).

### 4.4 [Alta] La documentación describe los tipos de dato de las respuestas, pero el código no maneja las violaciones

- **Ubicación:** `guides/08-distribution/04-request-handling.md:115-119` y docstring de `Malla.Request` (`lib/malla/plugins/request.ex:71-78`)
- **Problema:** La documentación indica que las respuestas de éxito deben tener `data` como "map or list" (`{:ok | :created, map | list}`), pero el servidor no maneja con gracia las respuestas que violan este contrato: crashea con `FunctionClauseError`. Además, existe una inconsistencia entre el docstring del plugin (que exige map/list) y la guía (que muestra `{:ok, data}` sin esa restricción).
- **Evidencia:** La guía (línea 118) muestra `{:ok | :created, map | list}` - Success with data, mientras `plugins/request.ex:185` usa `when result in [:ok, :created] and (is_map(data) or is_list(data))` sin cláusula de error posterior. El docstring de cliente en `lib/malla/request.ex:79-80` menciona "(map or list)" con terminología distinta a la guía.
- **Corrección sugerida:** Unificar la terminología del contrato entre guía y docstrings, y añadir una cláusula catch-all de error en el `case` (relacionado con 3.2 y 3.3), o bien documentar explícitamente que devolver datos en otros formatos es un error de programación que provocará crash.

### 4.5 [Media] La guía documenta `event/3` pero el moduledoc fuente no

- **Ubicación:** `guides/09-observability/01-tracing.md:87` vs `lib/malla/tracer.ex:44-45`
- **Problema:** La guía documenta `event(name, data \\ [], metadata \\ [])` mostrando los 3 parámetros, pero el moduledoc del módulo fuente solo lista `event/1` y `event/2`, creando confusión sobre la API real.
- **Evidencia:** La macro implementada en `tracer.ex:273-278` (`defmacro event(type, data \\ [], meta \\ [])`) soporta las tres aridades mediante parámetros por defecto. Sin embargo, la macro `__using__` (líneas 86-87) solo importa `event: 1` y `event: 2`, lo que crea una discrepancia real entre la API documentada en la guía y las aridades realmente exportadas.
- **Corrección sugerida:** Actualizar `lib/malla/tracer.ex:44-45` para documentar las tres aridades (`event/1`, `event/2`, `event/3`) y revisar el import de `__using__` para que sea coherente con la API ofrecida.

### 4.6 [Media] La opción de configuración `from_plugin` documentada no existe en la implementación

- **Ubicación:** `AGENTS.md:102`
- **Problema:** `AGENTS.md` lista "Remote config via `from_plugin:` option" como una de las capas de configuración, pero esta característica no aparece en `guides/07-configuration.md`, `guides/10-storage.md`, ni `README.md`, y no existe ninguna implementación en el código.
- **Evidencia:** Las búsquedas de `from_plugin` en todo el código (`.ex`, `.exs`, `.md`) lo encuentran **únicamente** en `AGENTS.md:102`. La lógica de fusión de configuración de `Malla.Service.Server` (`server.ex:361-507`) maneja config estática, config de OTP app y config en runtime, pero no implementa `from_plugin:`. No hay historial git que mencione la característica.
- **Corrección sugerida:** Implementar la característica `from_plugin` con su documentación, o eliminar la referencia de `AGENTS.md`. Si es trabajo planificado, añadir una nota que aclare ese estado.

### 4.7 [Baja] Retorno de callback inconsistente (`:cont` vs `:continue`) en el manejo de estado

- **Ubicación:** `lib/malla/plugins/status.ex:242` vs `lib/malla/plugins/status.ex:89` y `lib/malla/status.ex:191`
- **Problema:** El ejemplo del docstring (línea 89) muestra `defcb status(_), do: :cont`, pero la implementación real (línea 242) usa `defcb status(_), do: :continue`. El código de `status.ex:191` comprueba explícitamente `:continue`. Aunque el build acepta ambos, la inconsistencia genera confusión sobre qué valor usar.
- **Evidencia:** Ambos átomos son funcionalmente equivalentes en la cadena de plugins (`service/build.ex` líneas 138, 142, 147, 181, 185, 190 aceptan ambos), por lo que no es un bug funcional. `status.ex:191`: `case Malla.local(srv_id, :status, [user_status]) do :continue ->`.
- **Corrección sugerida:** Actualizar el ejemplo del docstring (línea 89) para usar `:continue`, o unificar la implementación con `:cont` para coincidir con `AGENTS.md`, que menciona `:cont` como valor estándar de continuación.

### 4.8 [Baja] El spec de retorno de `put_service_id` es incorrecto

- **Ubicación:** `lib/malla.ex:168`
- **Problema:** El `@spec` afirma que `put_service_id` retorna `id`, pero `Process.put()` retorna `nil` (o el valor previo) y `Process.delete()` retorna el valor antiguo o `nil`. El retorno real no está garantizado de ser el `id` pasado.
- **Evidencia:** La línea 168 declara `@spec put_service_id(id | nil) :: id`, pero las líneas 169-170 lo implementan con `Process.delete()` (retorna valor borrado o nil) y `Process.put()` (retorna nil). El valor de retorno no se captura ni se usa en ningún punto del código, por lo que el impacto práctico es nulo.
- **Corrección sugerida:** Cambiar el `@spec` a `@spec put_service_id(id | nil) :: id | nil`. Alternativamente, garantizar que la función retorne el parámetro `id` envolviendo las llamadas a `Process`.

### 4.9 [Baja] Formato de config de `precompile` inconsistente entre docstring y guías

- **Ubicación:** `lib/malla/node.ex:544-546` vs `guides/08-distribution/02-service-discovery.md:33-41`
- **Problema:** El docstring de `Malla.Node.precompile_stubs/0` muestra el formato de config como keyword list (`MyService: [...]`), pero las guías y los tests usan sintaxis de tupla (`{MyService, [...]}`).
- **Evidencia:** Docstring (línea 544): `config :malla, precompile: [MyService: [callback1: 0, callback2: 3]]`. Test (`node_precompile_test.exs:14-16`): `Application.put_env(:malla, :precompile, [{@test_service_name, test_callbacks}])`. En Elixir ambos formatos compilan a código idéntico (las keyword lists son azúcar sintáctico de listas de tuplas) y funcionan igual; el matching `{srv_id, callbacks}` acepta ambos. Es una inconsistencia puramente estilística.
- **Corrección sugerida:** Armonizar el docstring usando el formato de tupla `config :malla, precompile: [{MyService, [callback1: 0, callback2: 3]}]` para coincidir con guías y tests.

### 4.10 [Baja] Errata en el docstring de la macro `defcb` (sintaxis de átomo incorrecta) — `Plugin`

- **Ubicación:** `lib/malla/plugin.ex:205`
- **Problema:** El docstring de la macro `defcb` muestra `{:cont, [:a, b:]}`, pero el segundo elemento debería ser el átomo `:b`, no `b:`.
- **Evidencia:** Comparado con la línea 207 del mismo docstring, que muestra el ejemplo equivalente `{:cont, :a, :b}` con átomos en notación correcta.
- **Corrección sugerida:** Cambiar `b:` por `:b` en la línea 205 (`{:cont, [:a, :b]}`).

### 4.11 [Baja] Erratas en el docstring de la macro `Service.defcb` (sintaxis de átomo y conjunción faltante)

- **Ubicación:** `lib/malla/service.ex:583` y `lib/malla/service.ex:586`
- **Problema:** Dos erratas en el mismo docstring: (1) la línea 583 muestra `{:cont, [:a, b:]}` cuando el segundo elemento debería ser `:b`, error idéntico al de `Plugin.defcb` (probable copy-paste); (2) la línea 586 contiene "stops the call chain a returns this value", donde falta la conjunción "and".
- **Evidencia:** La línea 585 del mismo docstring ya muestra correctamente `{:cont, [:a, :b]}`. La línea 586: "any other response stops the call chain a returns this value to the caller".
- **Corrección sugerida:** Cambiar `b:` por `:b` en la línea 583 y "chain a returns" por "chain and returns" en la línea 586.

## 5. Propuestas de mejora

### 5.1 [Media] El tipo `call_result` es incompleto y engañoso — ✅ RESUELTO

Este punto es la misma cuestión que el bug 3.7. **Resuelto:** se añadió el tipo `remote_result` en `lib/malla.ex` documentando la forma de error real de `Malla.remote/4` (incluido `{:malla_rpc_error, ...}`), dejando `call_result` intacto en `lib/malla/node.ex:152` por ser correcto para la capa de node. Validado por Dialyzer.

### 5.2 [Baja] Comentario engañoso en `request.ex:199` sobre `trace_base` — ✅ RESUELTO

> **Resuelto:** comentario reemplazado por una explicación de la estrategia de doble nombrado (compat). Además se corrigió un tercer nombre erróneo en el docstring de `plugins/request.ex:152` (`base_span_id` → `base_span`). La lógica no se tocó.

- **Ubicación:** `lib/malla/request.ex:199`
- **Problema:** El comentario `# DELETED OLD trace_base` referencia código que ya no existe y no explica por qué se añaden tanto `:trace_base` como `:base_span` a `opts` (línea 200), confundiendo a futuros lectores sobre el doble nombrado.
- **Evidencia:** La línea 200 añade `[{:trace_base, base_span}, {:base_span, base_span} | opts]`, contradiciendo la implicación del comentario de que `trace_base` fue eliminado. La doble presencia es un patrón de retrocompatibilidad confirmado por la lógica de fallback en `plugins/request.ex:169-172`, donde se comprueba primero `:base_span` con `:trace_base` como respaldo.
- **Corrección sugerida:** Reemplazar el comentario por una explicación clara de la estrategia de compatibilidad, por ejemplo: `# Both trace_base and base_span are included for compatibility with plugins expecting either name`.

### 5.3 [Baja] ~~Pattern match redundante en `do_add_callbacks`~~ — DIAGNÓSTICO ERRÓNEO (rechazado)

> ⚠️ **CORRECCIÓN (verificado empíricamente):** el diagnóstico original de este punto es **incorrecto**. La cláusula `[{name, arity}]` **NO es código muerto**: es la vía activa para los callbacks de **todos los plugins**. Eliminarla rompería la compilación de cualquier servicio que use un plugin. **No aplicar la corrección sugerida original.**
>
> Existen dos representaciones distintas según el origen de `callbacks`:
> - **Módulo de servicio**: `Module.get_attribute(:plugin_callbacks)` en compile-time devuelve tuplas planas `{name, arity}` → coincide la 1ª cláusula (línea 301).
> - **Plugins**: `plugin.module_info()[:attributes]` + `Keyword.get_values/2` devuelve cada entrada `accumulate: true` **envuelta en una lista de un elemento** `[{name, arity}]` → coincide la 2ª cláusula (línea 313).
>
> Comprobado con `Malla.Plugins.Tracer.module_info()[:attributes]`, que produce `plugin_callbacks: [malla_span: 3]` (valor envuelto en lista). Que los 153 tests pasen confirma que ambas cláusulas son necesarias.
>
> **Mejora real aplicada:** corregir el comentario `(legacy?)` para documentar las dos representaciones y advertir explícitamente que la cláusula no debe eliminarse.

**Diagnóstico original (incorrecto), conservado para referencia:**

- **Ubicación:** `lib/malla/service/make.ex:309-313`
- **Problema (refutado):** afirmaba que la 2ª cláusula `[{name, arity}]` nunca coincide y es código muerto duplicado.
- **Corrección sugerida (NO aplicar):** eliminar la cláusula. Esto rompería el registro de callbacks de todos los plugins.

## 6. Resumen y prioridades

El análisis no detectó defectos críticos, pero sí siete bugs de severidad alta o media y un conjunto relevante de inconsistencias documentales. Destaca que el orden de dependencias en grupos de plugins, pese a parecer un bug, resulta correcto por compensación de inversiones sucesivas, aunque carece de tests que lo protejan. Las cinco acciones recomendadas con mayor prioridad son:

1. **Propagar errores de `plugin_updated` al reconfigurar** (`lib/malla/service/server.ex:224-225`) — corregir la supresión silenciosa de errores que puede dejar servicios en estado inconsistente.
2. **Unificar y endurecer el contrato de respuestas request/response** (`lib/malla/plugins/request.ex:180-198` y `lib/malla/request.ex:220-223`) — añadir cláusula catch-all en el servidor y alinear la validación cliente-servidor para evitar `FunctionClauseError` y comportamiento asimétrico en el sistema distribuido.
3. **Usar deep-merge real en la fusión de configuración** (`lib/malla/service/server.ex:514`) — sustituir `Keyword.merge` por `Malla.Util.keyword_merge` para no perder configuración anidada.
4. **Corregir la documentación de reconfiguración** (`guides/07a-reconfiguration.md:67`) — cambiar `{:restart, :configuration_changed}` por `{:ok, restart: true}`, ya que el ejemplo actual no funciona.
5. **Clarificar el orden de dependencias de grupos de plugins y añadir tests** (`lib/malla/service/make.ex:106-151`) — alinear comentario, código y guía, y fijar el orden de ejecución con tests; además, resolver las anotaciones de tipo erróneas (`Service.t`, `Config.update/3`, `call_result`) para mejorar la fiabilidad del análisis estático.

Como acciones de bajo coste y alto valor de mantenimiento, conviene aprovechar para corregir las erratas de los docstrings de `defcb`, eliminar el código muerto de `do_add_callbacks` y aclarar el comentario de `trace_base`.