# Discriminated-union submodule type for the generated config options.
#
# `types.oneOf [ (types.submodule …) (types.submodule …) ]` cannot act as a
# tagged union: every submodule's `check` is essentially `isAttrs`, so
# `oneOf` picks the first object variant for every attrset and later
# definitions are rejected against the wrong schema. This type instead
# reads the discriminator key out of the user's definitions and delegates
# merging to the specific variant `submodule` whose tag matches — so
# required fields, enum values, and unknown-field rejection all apply
# against the correct shape.
#
# Usage:
#   taggedSubmodule {
#     discriminator = "source";
#     variants = {
#       env  = { source = mkOption { type = enum [ "env"  ]; }; … };
#       file = { source = mkOption { type = enum [ "file" ]; }; path = mkOption { type = str; }; … };
#       exec = { source = mkOption { type = enum [ "exec" ]; }; command = mkOption { type = str; }; … };
#     };
#   }
{ lib }:
let
  t = lib.types;
  quoteList =
    sep: xs:
    lib.concatMapStringsSep sep (v: "\"" + v + "\"") xs;
in
{ discriminator, variants }:
let
  allowedTags = lib.attrNames variants;
in
lib.mkOptionType {
  name = "taggedSubmodule";
  description =
    "submodule tagged on `"
    + discriminator
    + "` ("
    + quoteList " | " allowedTags
    + ")";
  descriptionClass = "composite";
  check = x: builtins.isAttrs x || lib.isFunction x;
  merge =
    loc: defs:
    let
      optionPath = lib.showOption loc;
      readTag =
        def:
        if builtins.isAttrs def.value && def.value ? ${discriminator} then
          def.value.${discriminator}
        else
          null;
      presentTags = lib.unique (lib.filter (v: v != null) (map readTag defs));
    in
    if presentTags == [ ] then
      throw (
        "The option `"
        + optionPath
        + "' requires the discriminator `"
        + discriminator
        + "' to be set to one of "
        + quoteList ", " allowedTags
        + ", but none of its definitions provide a value. Definition files: "
        + lib.concatMapStringsSep ", " (d: toString d.file) defs
      )
    else if lib.length presentTags > 1 then
      throw (
        "Conflicting values for discriminator `"
        + discriminator
        + "' at option `"
        + optionPath
        + "': "
        + quoteList ", " presentTags
      )
    else
      let
        tag = lib.head presentTags;
      in
      if !(variants ? ${tag}) then
        throw (
          "Invalid value \""
          + tag
          + "\" for discriminator `"
          + discriminator
          + "' at option `"
          + optionPath
          + "': expected one of "
          + quoteList ", " allowedTags
          + "."
        )
      else
        (t.submodule { options = variants.${tag}; }).merge loc defs;
}
