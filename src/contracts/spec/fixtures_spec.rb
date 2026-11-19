require "yaml"

# Um teste por arquivo em v1/fixtures. A pasta decide o contrato e o resultado esperado.
# Cada pasta invalid/<contrato>/ tem um expected.yml com o motivo de cada fixture:
#
#   sem_brand.json: { pointer: "/brand", type: required }
#   sem_corpo.json:                       # mais de uma violação legítima: lista
#     - { pointer: "/a", type: required }
#     - { pointer: "/b", type: required }
#
# A fixture só passa se o validador devolver exatamente essas violações (pointer e type),
# nem mais nem menos. Assim uma fixture que falha também por outro motivo (erro de
# digitação, campo esquecido) não esconde a regra que ela deveria provar.
RSpec.describe "RNF-28: fixtures do contrato v1" do
  root = File.expand_path("../v1/fixtures", __dir__)

  it "tem fixtures válidas e inválidas para todos os contratos" do
    HelpdeskContracts.contracts.each do |contract|
      expect(Dir[File.join(root, "valid", contract.to_s, "*.json")]).not_to be_empty, "sem válida: #{contract}"
      expect(Dir[File.join(root, "invalid", contract.to_s, "*.json")]).not_to be_empty, "sem inválida: #{contract}"
    end
  end

  it "só tem pastas de contratos registrados" do
    folders = Dir[File.join(root, "{valid,invalid}", "*")].map { |dir| File.basename(dir).to_sym }.uniq

    expect(HelpdeskContracts.contracts).to include(*folders)
  end

  Dir[File.join(root, "invalid", "*")].sort.each do |dir|
    contract = File.basename(dir)

    it "invalid/#{contract}/expected.yml descreve exatamente as fixtures da pasta" do
      expected = YAML.safe_load_file(File.join(dir, "expected.yml"))
      files = Dir[File.join(dir, "*.json")].map { |path| File.basename(path) }

      expect(expected.keys).to match_array(files)
      expect(expected.values.flat_map { |v| v.is_a?(Array) ? v : [ v ] })
        .to all(match("pointer" => a_kind_of(String), "type" => a_kind_of(String)))
    end
  end

  Dir[File.join(root, "valid", "*", "*.json")].sort.each do |path|
    contract = File.basename(File.dirname(path))

    it "aceita valid/#{contract}/#{File.basename(path)}" do
      payload = JSON.parse(File.read(path, encoding: "UTF-8"))
      expect(HelpdeskContracts.errors(contract, payload)).to eq([])
    end
  end

  Dir[File.join(root, "invalid", "*", "*.json")].sort.each do |path|
    dir = File.dirname(path)
    contract = File.basename(dir)
    file = File.basename(path)

    it "rejeita invalid/#{contract}/#{file} pelo motivo esperado" do
      expected = YAML.safe_load_file(File.join(dir, "expected.yml")).fetch(file)
      expected = (expected.is_a?(Array) ? expected : [ expected ]).map { |v| v.slice("pointer", "type") }
      payload = JSON.parse(File.read(path, encoding: "UTF-8"))
      violations = HelpdeskContracts.errors(contract, payload).map { |v| { "pointer" => v.pointer, "type" => v.type } }

      expect(violations).to match_array(expected)
    end
  end
end
