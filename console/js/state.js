// Shared mutable state — the only state more than one view touches.
// ES module imports are live bindings, so importers see these updates; they must go through
// the setters below to change them (imported bindings are read-only at the import site).

export let DEVICES = [];          // device-registry list
export let CUR = null;            // open device: {uuid, device, ecus, sys, packages, events}
export const INSTALLED = {};      // uuid -> ECU list; mutated in place, never reassigned

export const setDevices = v => { DEVICES = v; };
export const setCur = v => { CUR = v; };
