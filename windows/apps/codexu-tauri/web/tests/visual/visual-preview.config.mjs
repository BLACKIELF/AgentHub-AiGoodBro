import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig, mergeConfig } from 'vite';
import appConfig from '../../vite.config.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, '..', '..');
const repoRoot = path.resolve(here, '..', '..', '..', '..', '..', '..');
const artifactRoot = process.env.CODEXU_VISUAL_ARTIFACT_ROOT
  ? path.resolve(webRoot, process.env.CODEXU_VISUAL_ARTIFACT_ROOT)
  : path.join(repoRoot, '.local-artifacts', 'visual');
const previewOutDir = path.join(artifactRoot, 'preview-dist');

const fixtureFiles = [
  'account-actions-component.fixture.tsx',
  'account-order-component.fixture.tsx',
  'appearance-component.fixture.tsx',
  'claude-swap-component.fixture.tsx',
  'companion-setup-component.fixture.tsx',
  'personal-wechat-text-component.fixture.tsx',
  'provider-navigation-component.fixture.tsx',
  'provider-pool-client-component.fixture.tsx',
  'provider-pool-component.fixture.tsx',
  'python-runtime-component.fixture.tsx',
  'recommendations-component.fixture.tsx',
  'runtime-setup-component.fixture.tsx',
];

const fixtureEntries = Object.fromEntries(fixtureFiles.map(file => [
  `tests/visual/${file.slice(0, -4)}`,
  path.join(here, file),
]));
const fixtureEntryNames = new Set(Object.keys(fixtureEntries));
const fixtureRoutes = new Map(fixtureFiles.map(file => {
  const sourcePath = `/tests/visual/${file}`;
  const outputPath = `/tests/visual/${file.slice(0, -4)}.js`;
  return [sourcePath, {
    outputPath,
    outputFile: path.join(previewOutDir, 'tests', 'visual', `${file.slice(0, -4)}.js`),
  }];
}));

function previewFixtureRoutes() {
  return {
    name: 'visual-preview-fixture-routes',
    configurePreviewServer(server) {
      const missing = [...fixtureRoutes.values()]
        .filter(({ outputFile }) => !existsSync(outputFile))
        .map(({ outputPath }) => outputPath);
      if (missing.length) throw new Error(`Visual fixture build output is missing: ${missing.join(', ')}`);

      server.middlewares.use((request, response, next) => {
        if (!request.url) return next();
        const queryAt = request.url.indexOf('?');
        const pathname = queryAt < 0 ? request.url : request.url.slice(0, queryAt);
        const route = fixtureRoutes.get(pathname);
        if (!route) return next();
        if (!existsSync(route.outputFile)) {
          response.statusCode = 404;
          response.end();
          return;
        }
        const query = queryAt < 0 ? '' : request.url.slice(queryAt);
        request.url = `${route.outputPath}${query}`;
        next();
      });
    },
  };
}

export default defineConfig(async environment => {
  const base = await (typeof appConfig === 'function' ? appConfig(environment) : appConfig);
  return mergeConfig(base, {
    build: {
      outDir: previewOutDir,
      emptyOutDir: true,
      rollupOptions: {
        preserveEntrySignatures: 'strict',
        input: {
          index: path.join(webRoot, 'index.html'),
          ...fixtureEntries,
        },
        output: {
          entryFileNames: chunk => fixtureEntryNames.has(chunk.name)
            ? `${chunk.name}.js`
            : 'assets/[name]-[hash].js',
        },
      },
    },
    plugins: [previewFixtureRoutes()],
  });
});
