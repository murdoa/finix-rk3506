# Embedded kernels have most drivers built-in, not as loadable modules.
# The module closure builder doesn't know about builtins and errors out.
# Same trick as nixos-xlnx/nixos-zedboard — let missing .ko files slide.
final: prev: {
  makeModulesClosure = x:
    prev.makeModulesClosure (x // { allowMissing = true; });
}
