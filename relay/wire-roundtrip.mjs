import { readFileSync, writeFileSync } from 'node:fs';
import { decodeBinary, encodeBinary } from './server.mjs';

const envelope = decodeBinary(readFileSync(process.argv[2]));
writeFileSync(process.argv[3], encodeBinary(envelope), { mode: 0o600 });
