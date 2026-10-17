// Import-map resolution (#1124). Each environment serves its own /importmap.json
// behind the gateway (#1128), so changing which remote build an environment runs
// needs no shell rebuild. public/importmap.json is the local-development map.

interface ImportMap {
  imports: Record<string, string>;
}

let cached: Promise<ImportMap> | undefined;

async function fetchImportMap(): Promise<ImportMap> {
  const response = await fetch("/importmap.json");
  if (!response.ok) throw new Error(`/importmap.json: HTTP ${response.status}`);
  const body: unknown = await response.json();
  const imports = (body as Partial<ImportMap> | null)?.imports;
  if (typeof imports !== "object" || imports === null) throw new Error("/importmap.json has no imports object");
  return { imports };
}

/** Fetched at most once per page load, then cached; a failed fetch is not cached. */
function loadImportMap(): Promise<ImportMap> {
  cached ??= fetchImportMap().catch((error: unknown) => {
    cached = undefined;
    throw error;
  });
  return cached;
}

/** The URL /importmap.json maps `specifier` to; rejects naming an unknown one. */
export async function resolveSpecifier(specifier: string): Promise<string> {
  const map = await loadImportMap();
  const url = map.imports[specifier];
  if (typeof url !== "string") throw new Error(`unknown remote specifier: ${specifier}`);
  return url;
}
