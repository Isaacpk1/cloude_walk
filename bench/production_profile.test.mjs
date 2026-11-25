// RNF-29/RNF-30: verifica o resultado real da combinação dos arquivos Compose.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

test("RNF-30: perfil de carga usa imagem, production e armazenamento isolado", () => {
  const profile = JSON.parse(execFileSync("docker", ["compose", "-p", "helpdesk-bench", "-f", "docker-compose.yml", "-f", "docker-compose.bench.yml", "config", "--format", "json"], { encoding: "utf8" }));
  for (const name of ["web", "worker", "scheduler", "consumer"]) {
    const service = profile.services[name];
    assert.equal(service.environment.RAILS_ENV, "production");
    assert.equal(service.environment.POSTGRES_DB, "helpdesk_benchmark");
    assert.equal((service.volumes || []).length, 0);
  }
  assert.equal(profile.name, "helpdesk-bench");
  assert.equal(profile.services.web.ports[0].host_ip, "127.0.0.1");
});
