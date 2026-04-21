import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const args = process.argv.slice(2);
const argValue = (flag: string): string | null => {
  const idx = args.indexOf(flag);
  if (idx === -1 || idx + 1 >= args.length) return null;
  return args[idx + 1];
};

const repo = argValue("--repo") ?? process.cwd();
const outPath = argValue("--out") ?? path.join(process.cwd(), "nix/generated/openclaw-config-options.nix");
const schemaRev = argValue("--rev") ?? process.env.OPENCLAW_SCHEMA_REV ?? null;

const schemaPath = path.join(repo, "src/config/zod-schema.ts");
const schemaUrl = pathToFileURL(schemaPath).href;

const loadSchema = async (): Promise<Record<string, unknown>> => {
  const mod = await import(schemaUrl);
  const schema = mod.OpenClawSchema;
  if (!schema || typeof schema.toJSONSchema !== "function") {
    console.error(`OpenClawSchema not found at ${schemaPath}`);
    process.exit(1);
  }
  return schema.toJSONSchema({
    target: "draft-07",
    unrepresentable: "any",
  }) as Record<string, unknown>;
};

const main = async (): Promise<void> => {
  const schema = await loadSchema();
  const definitions: Record<string, unknown> =
    (schema.definitions as Record<string, unknown>) ||
    (schema.$defs as Record<string, unknown>) ||
    {};

const stringify = (value: string): string => {
  const escaped = value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
  return `"${escaped}"`;
};

const nixAttr = (key: string): string => {
  if (/^[A-Za-z_][A-Za-z0-9_']*$/.test(key)) return key;
  return stringify(key);
};

const nixLiteral = (value: unknown): string => {
  if (value === null) return "null";
  if (typeof value === "string") return stringify(value);
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (Array.isArray(value)) {
    return `[ ${value.map(nixLiteral).join(" ")} ]`;
  }
  return "null";
};

type JsonSchema = Record<string, unknown>;

const resolveRef = (ref: string): JsonSchema | null => {
  const prefixDefs = "#/definitions/";
  const prefixDefsAlt = "#/$defs/";
  if (ref.startsWith(prefixDefs)) {
    const name = ref.slice(prefixDefs.length);
    return (definitions[name] as JsonSchema) || null;
  }
  if (ref.startsWith(prefixDefsAlt)) {
    const name = ref.slice(prefixDefsAlt.length);
    return (definitions[name] as JsonSchema) || null;
  }
  return null;
};

const deref = (input: JsonSchema, seen: Set<string>): JsonSchema => {
  if (input.$ref && typeof input.$ref === "string") {
    const ref = input.$ref as string;
    if (seen.has(ref)) {
      return {};
    }
    const resolved = resolveRef(ref);
    if (!resolved) return {};
    const nextSeen = new Set(seen);
    nextSeen.add(ref);
    return deref(resolved, nextSeen);
  }
  return input;
};

const isNullSchema = (value: unknown): boolean => {
  if (!value || typeof value !== "object") return false;
  const schemaObj = value as JsonSchema;
  if (schemaObj.type === "null") return true;
  if (Array.isArray(schemaObj.type)) return schemaObj.type.includes("null");
  return false;
};

const stripNullable = (schemaObj: JsonSchema): { schema: JsonSchema; nullable: boolean } => {
  const schema = deref(schemaObj, new Set());
  if (schema.anyOf && Array.isArray(schema.anyOf)) {
    const entries = schema.anyOf as JsonSchema[];
    const nullable = entries.some(isNullSchema);
    const next = entries.filter((entry) => !isNullSchema(entry));
    return {
      schema: { ...schema, anyOf: next },
      nullable,
    };
  }
  if (schema.oneOf && Array.isArray(schema.oneOf)) {
    const entries = schema.oneOf as JsonSchema[];
    const nullable = entries.some(isNullSchema);
    const next = entries.filter((entry) => !isNullSchema(entry));
    return {
      schema: { ...schema, oneOf: next },
      nullable,
    };
  }
  if (Array.isArray(schema.type)) {
    const nullable = schema.type.includes("null");
    const nextTypes = schema.type.filter((t) => t !== "null");
    const nextSchema = { ...schema };
    if (nextTypes.length === 1) {
      nextSchema.type = nextTypes[0];
    } else {
      nextSchema.type = nextTypes;
    }
    return { schema: nextSchema, nullable };
  }
  return { schema, nullable: false };
};

const typeForSchema = (schemaObj: JsonSchema, indent: string): string => {
  const { schema, nullable } = stripNullable(schemaObj);
  const typeExpr = baseTypeForSchema(schema, indent);
  if (nullable) {
    return `t.nullOr (${typeExpr})`;
  }
  return typeExpr;
};

const isObjectLikeSchema = (schemaObj: JsonSchema): boolean => {
  const schema = deref(schemaObj, new Set());
  if (schema.type === "object") return true;
  if (schema.properties !== undefined) return true;
  if (schema.additionalProperties !== undefined) return true;
  return false;
};

// Drop non-semantic metadata when comparing schemas for deduplication.
// `description`, `title`, examples, etc. do not affect the generated Nix
// type, so two branches that differ only in those fields hash equal. Use a
// deny-list (not an allow-list) so we recurse correctly into nodes with
// arbitrary child keys — e.g., `properties` whose keys are domain names
// like "source", "id", "provider" rather than JSON-schema meta keys.
const NON_SEMANTIC_KEYS = new Set([
  "description",
  "title",
  "markdownDescription",
  "examples",
  "example",
  "$comment",
  "deprecated",
  "readOnly",
  "writeOnly",
  "$id",
  "$schema",
  "$anchor",
]);

const normalizeForHash = (value: unknown): unknown => {
  if (value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map(normalizeForHash);
  const obj = value as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(obj).sort()) {
    if (NON_SEMANTIC_KEYS.has(key)) continue;
    out[key] = normalizeForHash(obj[key]);
  }
  return out;
};

const schemaHashKey = (schema: unknown): string => JSON.stringify(normalizeForHash(schema));

const dedupeSchemas = (branches: JsonSchema[]): JsonSchema[] => {
  const seen = new Set<string>();
  const out: JsonSchema[] = [];
  for (const branch of branches) {
    const key = schemaHashKey(branch);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(branch);
  }
  return out;
};

const constStringTag = (schemaObj: JsonSchema | undefined): string | null => {
  if (schemaObj === undefined) return null;
  const d = deref(schemaObj, new Set());
  if (typeof d.const === "string") return d.const;
  if (Array.isArray(d.enum) && d.enum.length === 1 && typeof d.enum[0] === "string") {
    return d.enum[0];
  }
  return null;
};

type Discriminator = {
  discriminator: string;
  variants: { tag: string; schema: JsonSchema }[];
};

const tryDiscriminator = (branches: JsonSchema[]): Discriminator | null => {
  if (branches.length < 2) return null;
  const derefed = branches.map((b) => deref(b, new Set()));
  if (!derefed.every(isObjectLikeSchema)) return null;

  const propsPerBranch = derefed.map(
    (b) => (b.properties as Record<string, JsonSchema>) || {},
  );
  let commonKeys = Object.keys(propsPerBranch[0]);
  for (let i = 1; i < propsPerBranch.length; i++) {
    const keys = new Set(Object.keys(propsPerBranch[i]));
    commonKeys = commonKeys.filter((k) => keys.has(k));
  }

  for (const key of commonKeys.sort()) {
    const tags = propsPerBranch.map((props) => constStringTag(props[key]));
    if (tags.some((t) => t === null)) continue;
    const unique = new Set(tags);
    if (unique.size !== tags.length) continue; // duplicate tag → not a discriminator
    return {
      discriminator: key,
      variants: tags.map((tag, i) => ({ tag: tag as string, schema: derefed[i] })),
    };
  }
  return null;
};

const renderVariantOptions = (variant: JsonSchema, indent: string): string => {
  const props = (variant.properties as Record<string, JsonSchema>) || {};
  const required = new Set((variant.required as string[]) || []);
  const keys = Object.keys(props).sort();
  return keys
    .map((key) => renderOption(key, props[key], required.has(key), indent))
    .join("\n");
};

const renderTaggedSubmodule = (disc: Discriminator, indent: string): string => {
  const variantsIndent = `${indent}  `;
  const variantIndent = `${variantsIndent}  `;
  const optionIndent = `${variantIndent}  `;
  const sorted = [...disc.variants].sort((a, b) => a.tag.localeCompare(b.tag));
  const lines: string[] = [];
  lines.push(`taggedSubmodule {`);
  lines.push(`${variantsIndent}discriminator = ${stringify(disc.discriminator)};`);
  lines.push(`${variantsIndent}variants = {`);
  for (const { tag, schema } of sorted) {
    lines.push(`${variantIndent}${nixAttr(tag)} = {`);
    const body = renderVariantOptions(schema, optionIndent);
    if (body.length > 0) lines.push(body);
    lines.push(`${variantIndent}};`);
  }
  lines.push(`${variantsIndent}};`);
  lines.push(`${indent}}`);
  return lines.join("\n");
};

// Last-resort fallback for object-only unions where no discriminator can be
// identified. Merges all branches into a single permissive submodule.
// Loses required-field constraints — prefer fixing the upstream schema to
// use a tagged union so this branch isn't hit.
const mergeObjectBranches = (branches: JsonSchema[]): JsonSchema => {
  const propertyVariants: Record<string, JsonSchema[]> = {};
  let additional: JsonSchema | boolean | undefined;
  for (const raw of branches) {
    const branch = deref(raw, new Set());
    const props = (branch.properties as Record<string, JsonSchema>) || {};
    for (const [key, value] of Object.entries(props)) {
      if (!propertyVariants[key]) propertyVariants[key] = [];
      propertyVariants[key].push(value);
    }
    if (branch.additionalProperties !== undefined && additional === undefined) {
      additional = branch.additionalProperties as JsonSchema | boolean;
    }
  }

  const mergedProps: Record<string, JsonSchema> = {};
  for (const [key, variants] of Object.entries(propertyVariants)) {
    const unique = dedupeSchemas(variants);
    if (unique.length === 1) {
      mergedProps[key] = unique[0];
      continue;
    }
    const allEnumish = unique.every((v) => {
      const d = deref(v, new Set());
      return d.const !== undefined || Array.isArray(d.enum);
    });
    if (allEnumish) {
      const values: unknown[] = [];
      for (const v of unique) {
        const d = deref(v, new Set());
        if (d.const !== undefined) {
          if (!values.some((x) => JSON.stringify(x) === JSON.stringify(d.const))) {
            values.push(d.const);
          }
        } else if (Array.isArray(d.enum)) {
          for (const entry of d.enum) {
            if (!values.some((x) => JSON.stringify(x) === JSON.stringify(entry))) {
              values.push(entry);
            }
          }
        }
      }
      mergedProps[key] = { enum: values };
      continue;
    }
    if (unique.every(isObjectLikeSchema)) {
      const discInner = tryDiscriminator(unique);
      if (discInner) {
        mergedProps[key] = { _taggedDiscriminator: discInner } as unknown as JsonSchema;
      } else {
        mergedProps[key] = mergeObjectBranches(unique);
      }
      continue;
    }
    mergedProps[key] = { anyOf: unique };
  }

  const result: JsonSchema = {
    type: "object",
    properties: mergedProps,
    required: [],
  };
  if (additional !== undefined) {
    result.additionalProperties = additional;
  }
  return result;
};

const baseTypeForSchema = (schemaObj: JsonSchema, indent: string): string => {
  const schema = deref(schemaObj, new Set());
  if (schema.const !== undefined) {
    return `t.enum [ ${nixLiteral(schema.const)} ]`;
  }
  if (Array.isArray(schema.enum)) {
    const values = schema.enum.map((value) => nixLiteral(value)).join(" ");
    return `t.enum [ ${values} ]`;
  }

  // Carrier used by the merge fallback to smuggle a discriminator through.
  if ((schema as { _taggedDiscriminator?: Discriminator })._taggedDiscriminator) {
    return renderTaggedSubmodule(
      (schema as { _taggedDiscriminator: Discriminator })._taggedDiscriminator,
      indent,
    );
  }

  // Nix's `types.oneOf` picks a variant via each variant's `check` function.
  // Submodules' `check` is essentially `isAttrs`, so every attrset passes
  // the first object-variant's check and `oneOf [sub1 sub2 ...]` always
  // resolves to sub1 regardless of the value's shape. For object branches
  // we need a discriminator-aware type instead. Primitive branches (str,
  // int, bool, …) have discriminating checks and work in `oneOf` as-is.
  const unionBranchesRaw =
    schema.anyOf && Array.isArray(schema.anyOf) && schema.anyOf.length > 0
      ? (schema.anyOf as JsonSchema[])
      : schema.oneOf && Array.isArray(schema.oneOf) && schema.oneOf.length > 0
        ? (schema.oneOf as JsonSchema[])
        : null;
  if (unionBranchesRaw) {
    const branches = dedupeSchemas(unionBranchesRaw);
    if (branches.length === 1) {
      return typeForSchema(branches[0], indent);
    }

    const objectBranches = branches.filter(isObjectLikeSchema);
    const primitiveBranches = branches.filter((b) => !isObjectLikeSchema(b));

    if (objectBranches.length === 0) {
      const parts = primitiveBranches
        .map((e) => `(${typeForSchema(e, indent)})`)
        .join(" ");
      return `t.oneOf [ ${parts} ]`;
    }

    let objectTypeExpr: string;
    if (objectBranches.length === 1) {
      objectTypeExpr = objectTypeForSchema(objectBranches[0], indent);
    } else {
      const disc = tryDiscriminator(objectBranches);
      if (disc) {
        objectTypeExpr = renderTaggedSubmodule(disc, indent);
      } else {
        console.warn(
          "[generate-config-options] object-only union without a discriminator " +
            "property; falling back to permissive merged submodule (required-field " +
            "constraints will be lost for this location).",
        );
        objectTypeExpr = objectTypeForSchema(mergeObjectBranches(objectBranches), indent);
      }
    }

    if (primitiveBranches.length === 0) {
      return objectTypeExpr;
    }
    const parts = [
      ...primitiveBranches.map((e) => `(${typeForSchema(e, indent)})`),
      `(${objectTypeExpr})`,
    ].join(" ");
    return `t.oneOf [ ${parts} ]`;
  }

  if (schema.allOf && Array.isArray(schema.allOf) && schema.allOf.length > 0) {
    return "t.anything";
  }

  const schemaType = schema.type;
  if (Array.isArray(schemaType) && schemaType.length > 0) {
    const parts = schemaType
      .map((entry) => `(${typeForSchema({ type: entry }, indent)})`)
      .join(" ");
    return `t.oneOf [ ${parts} ]`;
  }

  switch (schemaType) {
    case "string":
      return "t.str";
    case "number":
      return "t.number";
    case "integer":
      return "t.int";
    case "boolean":
      return "t.bool";
    case "array": {
      const items = (schema.items as JsonSchema) || {};
      return `t.listOf (${typeForSchema(items, indent)})`;
    }
    case "object":
      return objectTypeForSchema(schema, indent);
    case undefined:
      if (schema.properties || schema.additionalProperties) {
        return objectTypeForSchema(schema, indent);
      }
      return "t.anything";
    default:
      return "t.anything";
  }
};

const objectTypeForSchema = (schema: JsonSchema, indent: string): string => {
  const properties = (schema.properties as Record<string, JsonSchema>) || {};
  const requiredList = new Set((schema.required as string[]) || []);
  const keys = Object.keys(properties);

  if (keys.length === 0) {
    if (schema.additionalProperties && typeof schema.additionalProperties === "object") {
      const valueType = typeForSchema(schema.additionalProperties as JsonSchema, indent);
      return `t.attrsOf (${valueType})`;
    }
    if (schema.additionalProperties === true) {
      return "t.attrs";
    }
    return "t.attrs";
  }

  const nextIndent = `${indent}  `;
  const inner = keys
    .sort()
    .map((key) => renderOption(key, properties[key], requiredList.has(key), nextIndent))
    .join("\n");

  return `t.submodule { options = {\n${inner}\n${indent}}; }`;
};

const renderOption = (key: string, schemaObj: JsonSchema, required: boolean, indent: string): string => {
  const schema = deref(schemaObj, new Set());
  const description = typeof schema.description === "string" ? schema.description : null;
  const hasSchemaDefault = schema.default !== undefined;
  const effectiveRequired = required && !hasSchemaDefault;
  const baseTypeExpr = typeForSchema(schema, indent);
  const typeExpr =
    !effectiveRequired && !baseTypeExpr.startsWith("t.nullOr")
      ? `t.nullOr (${baseTypeExpr})`
      : baseTypeExpr;
  const lines = [
    `${indent}${nixAttr(key)} = lib.mkOption {`,
    `${indent}  type = ${typeExpr};`,
  ];
  if (!effectiveRequired) {
    lines.push(`${indent}  default = null;`);
  }
  if (description) {
    lines.push(`${indent}  description = ${stringify(description)};`);
  }
  lines.push(`${indent}};`);
  return lines.join("\n");
};

  const rootSchema = deref(schema as JsonSchema, new Set());
  const rootProps = (rootSchema.properties as Record<string, JsonSchema>) || {};
  const requiredRoot = new Set((rootSchema.required as string[]) || []);

  const body = Object.keys(rootProps)
    .sort()
    .map((key) => renderOption(key, rootProps[key], requiredRoot.has(key), "  "))
    .join("\n\n");

  const header = schemaRev
    ? `# Generated from upstream OpenClaw schema at rev ${schemaRev}. DO NOT EDIT.`
    : "# Generated from upstream OpenClaw schema. DO NOT EDIT.";

  const output = `${header}\n# Generator: nix/scripts/generate-config-options.ts\n{ lib }:\nlet\n  t = lib.types;\n  taggedSubmodule = import ./tagged-submodule.nix { inherit lib; };\nin\n{\n${body}\n}\n`;

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, output, "utf8");
};

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
