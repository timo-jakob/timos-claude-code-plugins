// Host-side config validation (#1939): a hand-rolled JSON-Schema subset, so the
// canvas carries no runtime validator dependency. A schema using any keyword
// outside the subset fails closed — the instance is not mounted.

import type { WidgetManifest } from "@{{NPM_SCOPE}}/mfe-contract";
import { CONTRACT_MAJOR } from "./canvas";

export type Validation =
  | { ok: true }
  | { ok: false; reason: "rule"; path: string; rule: string }
  | { ok: false; reason: "unsupported"; path: string; keyword: string };

const SUPPORTED = new Set([
  "type",
  "properties",
  "required",
  "enum",
  "const",
  "minimum",
  "maximum",
  "minLength",
  "maxLength",
  "items",
  "additionalProperties",
]);

type Schema = Record<string, unknown>;

function typeOf(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (typeof value === "number") return Number.isInteger(value) ? "integer" : "number";
  return typeof value;
}

function hasType(value: unknown, type: unknown): boolean {
  const actual = typeOf(value);
  const wanted = Array.isArray(type) ? type : [type];
  return wanted.some((name) => name === actual || (name === "number" && actual === "integer"));
}

function equal(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function check(schema: Schema, value: unknown, path: string): Validation {
  for (const keyword of Object.keys(schema)) {
    if (!SUPPORTED.has(keyword)) return { ok: false, reason: "unsupported", path, keyword };
  }
  if (schema.additionalProperties !== undefined && schema.additionalProperties !== false) {
    return { ok: false, reason: "unsupported", path, keyword: "additionalProperties" };
  }
  const fail = (rule: string): Validation => ({ ok: false, reason: "rule", path, rule });
  if (schema.type !== undefined && !hasType(value, schema.type)) return fail("type");
  if (Array.isArray(schema.enum) && !schema.enum.some((option) => equal(option, value))) return fail("enum");
  if ("const" in schema && !equal(schema.const, value)) return fail("const");
  if (typeof value === "number") {
    if (typeof schema.minimum === "number" && value < schema.minimum) return fail("minimum");
    if (typeof schema.maximum === "number" && value > schema.maximum) return fail("maximum");
  }
  if (typeof value === "string") {
    if (typeof schema.minLength === "number" && value.length < schema.minLength) return fail("minLength");
    if (typeof schema.maxLength === "number" && value.length > schema.maxLength) return fail("maxLength");
  }
  if (Array.isArray(value) && typeof schema.items === "object" && schema.items !== null) {
    for (const [index, item] of value.entries()) {
      const result = check(schema.items as Schema, item, `${path}[${index}]`);
      if (!result.ok) return result;
    }
  }
  if (typeOf(value) === "object") {
    const record = value as Record<string, unknown>;
    const properties = (schema.properties ?? {}) as Record<string, Schema>;
    for (const name of Array.isArray(schema.required) ? schema.required : []) {
      const key = String(name);
      if (!(key in record)) return { ok: false, reason: "rule", path: `${path}.${key}`, rule: "required" };
    }
    for (const [name, item] of Object.entries(record)) {
      const property = properties[name];
      if (property === undefined) {
        if (schema.additionalProperties === false) {
          return { ok: false, reason: "rule", path: `${path}.${name}`, rule: "additionalProperties" };
        }
        continue;
      }
      const result = check(property, item, `${path}.${name}`);
      if (!result.ok) return result;
    }
  }
  return { ok: true };
}

/** Validates `config` against a widget's `manifest.configSchema`; the first failure wins. */
export function validateConfig(schema: object, config: unknown): Validation {
  return check(schema as Schema, config, "$");
}

/** Why an instance must not be mounted, or null: a contract-major mismatch, an invalid config, a bad schema. */
export function mountRefusal(manifest: WidgetManifest, config: unknown): string | null {
  if (manifest.contractMajor !== CONTRACT_MAJOR) {
    const target = `This widget targets mfe-contract major ${manifest.contractMajor}`;
    return `${target}; this canvas mounts major ${CONTRACT_MAJOR}.`;
  }
  const result = validateConfig(manifest.configSchema, config);
  if (result.ok) return null;
  if (result.reason === "unsupported") {
    return `This widget's config schema uses the unsupported keyword "${result.keyword}" at ${result.path}.`;
  }
  return `This widget's config fails "${result.rule}" at ${result.path}.`;
}
