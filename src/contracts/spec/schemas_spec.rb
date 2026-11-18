RSpec.describe "RNF-28: esquemas JSON do v1" do
  schemas = Dir[File.expand_path("../v1/schemas/**/*.json", __dir__)].sort
  parsed = schemas.to_h { |path| [ path, JSON.parse(File.read(path, encoding: "UTF-8")) ] }

  it "cobre todos os contratos do registro" do
    expected = HelpdeskContracts::CONTRACTS.values.map { |spec| spec[:file] }
    found = schemas.map { |path| path.split("/v1/schemas/").last }

    expect(found).to match_array(expected)
  end

  it "usa um $id único por esquema" do
    ids = parsed.values.map { |schema| schema["$id"] }

    expect(ids).to all(start_with("https://contracts.helpdesk.cloudwalk.local/v1/"))
    expect(ids.uniq.size).to eq(schemas.size)
  end

  parsed.each do |path, schema|
    name = path.split("/v1/schemas/").last

    it "#{name} é draft 2020-12 válido no metaesquema" do
      expect(schema["$schema"]).to eq("https://json-schema.org/draft/2020-12/schema")
      expect(JSONSchemer.draft202012.valid?(schema)).to be(true)
    end

    it "#{name} não fecha additionalProperties (07, seção 5.4)" do
      expect(JSON.generate(schema)).not_to include('"additionalProperties":false')
      expect(JSON.generate(schema)).not_to include('"unevaluatedProperties":false')
    end
  end
end
