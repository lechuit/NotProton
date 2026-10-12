'use strict';
const assert = require('assert/strict');
const { execFileSync } = require('child_process');
const { walk } = require('./harness');

const emit = process.argv[2];
const state = execFileSync(emit, ['forcetool-state'], { encoding: 'utf8' });
const picker = execFileSync(emit, ['forcetool-picker'], { encoding: 'utf8' });
const native = 'notproton-wine-native-wine-11.17';
const tools = [{ strToolName: 'notproton-26.3', strDisplayName: 'CrossOver 26.3' },
               { strToolName: native, strDisplayName: 'Native Steam' }];
const calls = [];
const i = { jsx: (type, props) => ({ type, props }),
            jsxs: (type, props) => ({ type, props }), Fragment: 'Fragment' };
const n = { useState: initial => [Array.isArray(initial) ? tools : initial, () => {}],
            useEffect: () => {} };
const s = { q3: f => f() };
const u = { rV: { settings: { bCompatEnabled: false, strCompatTool: 'notproton-26.3' } } };
const client = { Apps: { SpecifyCompatTool: (...args) => calls.push(args) } };
const body = 'const t=details;let ' + state + ',d=a.map(e=>({data:e.strToolName,label:e.strDisplayName})),g=o,C=()=>{};' + picker;
const render = new Function('details', 'i', 'n', 's', 'u', 'h', 'A', '_r', 'c', 'K', 'SteamClient', body);
const show = details => walk(render(details, i, n, s, u, { JN: 250 }, { we: x => x },
  'Toggle', { m: 'Dropdown' }, () => ({ TopGap: 'gap' }), client));
const saved = { unAppID: 3393110, strCompatToolName: native, nCompatToolPriority: 250 };
let nodes = show(saved);
let toggle = nodes.find(x => x.type === 'Toggle');
assert.equal(toggle.props.checked, true, 'saved per-app choice survives a disabled global setting');
assert.equal(toggle.props.disabled, false, 'the available per-app picker remains enabled');
const dropdown = nodes.find(x => x.type === 'Dropdown');
assert.equal(dropdown.props.selectedOption, native);
dropdown.props.onChange({ data: native });
assert.deepEqual(calls.at(-1), [3393110, native], 'the existing client mapping API receives the exact choice');
nodes = show({ ...saved, nCompatToolPriority: 75 });
assert.equal(nodes.find(x => x.type === 'Toggle').props.checked, false, 'global priority is not shown as a per-app force');
assert.equal(nodes.some(x => x.type === 'Dropdown'), false);
nodes = show({ ...saved, strCompatToolName: '' });
assert.equal(nodes.find(x => x.type === 'Toggle').props.checked, false);
console.log('==> forcetool: saved native selection survives bCompatEnabled=false; per-app priority and API preserved');
