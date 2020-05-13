require 'spec_helper'
require 'securerandom'

module Vault
  describe Transform, ent_vault: ">= 1.4" do
    subject { vault_test_client }

    before(:context) do
      vault_test_client.sys.mount(
        "transform", "transform", "transform"
      )
      vault_test_client.transform.create_role("foo_role", transformations: ["foo_trans"])
      vault_test_client.transform.create_transformation("foo_trans", type: "fpe", template: "builtin/creditcardnumber", allowed_roles: ["foo_role"])
    end

    base_names = Proc.new { SecureRandom.alphanumeric(5) }
    trans_types = ['fpe', 'masking']
    trans_tweak_sources = ['supplied', 'generated', 'internal']
    trans_templates = ['builtin/creditcardnumber', 'builtin/socialsecuritynumber']
    temp_types = ["regex"]
    temp_patterns = ['\d{3}-\d{2}-\d{4}', '\d{3}-\d{3}-\d{4}', '\d{4}-\d{4}-\d{4}-\d{4}']
    alpha_sets = ['1234567890abcdef', 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ']

    transform_types = {
      role: { name: base_names, other_attrs: { transformations: [["foo_trans"]] } },
      transformation: { name: base_names, other_attrs: { type: trans_types, tweak_source: trans_tweak_sources, template: trans_templates } },
      template: { name: base_names, other_attrs: { type: temp_types, pattern: temp_patterns } },
      alphabet: { name: base_names, other_attrs: { alphabet: alpha_sets } },
    }

    transform_types.each do |type, attrs|
      context "#{type.capitalize}" do
        attr_values = attrs[:other_attrs].values
        attr_keys = attrs[:other_attrs].keys

        (0...(attr_values[0]&.length || 1)).each do |index_0|
          (0...(attr_values[1]&.length || 1)).each do |index_1|
            (0...(attr_values[2]&.length || 1)).each do |index_2|
              let(:opts) do
                opts = {}
                opts[attr_keys[0].to_sym] = attr_values[0][index_0] if attr_values[0]
                opts[attr_keys[1].to_sym] = attr_values[1][index_1] if attr_values[1]
                opts[attr_keys[2].to_sym] = attr_values[2][index_2] if attr_values[2]
                opts
              end
              
              before(:context) do
                @name = "#{attrs[:name].call}_#{type}".downcase
              end

              context "CRUD", order: :defined do
                describe "#create_#{type}" do
                  it "creates a #{type} in the vault server" do
                    subject.transform.send("create_#{type}", @name, **opts)
                    expected_opts = opts.clone
                    expected_opts.delete(:tweak_source) if opts[:tweak_source] == "internal"
                    if type == :transformation
                      expected_opts[:allowed_roles] = [] 
                      expected_opts[:templates] = [opts[:template]]
                    end

                    expected = Vault::Transform.const_get(type.to_s.capitalize).new(expected_opts)
                    expect(subject.transform.send("get_#{type}", @name)).to eq(expected)
                  end
                end

                describe "##{type}s" do
                  it "lists the names of all #{type}s present on the vault server" do
                    expect(subject.transform.send("#{type}s")).to include(@name)
                  end
                end

                describe "#delete_#{type}" do
                  it "removes the #{type} from the server" do
                    subject.transform.send("delete_#{type}", @name)
                    expect(subject.transform.send("#{type}s")).not_to include(@name)
                  end
                end
              end
            end
          end
        end
      end
    end

    describe "#encode and #decode" do
      let(:value) { "4111-1111-1111-1111"}
      let(:tweak) { Base64.encode64("somenum") }

      it "encodes a value with a supplied tweak value then decodes it to the original value" do
        resp = subject.transform.encode(role_name: "foo_role", value: value, tweak: tweak)
        encoded_value = resp[:data][:encoded_value]
        expect(encoded_value).to match(/\d{4}-\d{4}-\d{4}-\d{4}/)
        expect(encoded_value).not_to eq(value)
        resp = subject.transform.decode(role_name: "foo_role", value: encoded_value, tweak: tweak)
        expect(resp[:data][:decoded_value]).to eq(value)
      end

      it "does not output the original value if the same tweak was not supplied" do
        resp = subject.transform.encode(role_name: "foo_role", value: value, tweak: tweak)
        encoded_value = resp[:data][:encoded_value]
        resp = subject.transform.decode(role_name: "foo_role", value: encoded_value, tweak: Base64.encode64("numsome"))
        expect(resp[:data][:decoded_value]).to_not eq(value)
        expect(resp[:data][:decoded_value]).to_not eq(encoded_value)
        expect(resp[:data][:decoded_value]).to match(/\d{4}-\d{4}-\d{4}-\d{4}/)
      end

      context "with a transformation" do
        let(:allowed_roles) { ["foo_role"] }
        let(:trans_name) { "#{type}_#{tweak_source}_#{template.gsub('/','-')}" }
        let(:role) { "foo_role" }
        before do
          subject.transform.create_transformation(trans_name, type: type, template: template, tweak_source: tweak_source, allowed_roles: allowed_roles)
        end

        context "with an fpe type" do
          let(:type) { "fpe" }

          context "and a credit card template" do
            let(:template_regex) { /\d{4}-\d{4}-\d{4}-\d{4}/ }
            let(:template) { "builtin/creditcardnumber" }
            let(:value) { "4111-1111-1111-1111"}

            context "and a supplied tweak source" do
              let(:tweak_source) { "supplied" }

              it "encodes a value and decodes it to the original value" do
                resp = subject.transform.encode(role_name: "foo_role", value: value, tweak: tweak, transformation: trans_name)
                encoded_value = resp[:data][:encoded_value]
                expect(encoded_value).to match(template_regex)
                expect(encoded_value).not_to eq(value)
                resp = subject.transform.decode(role_name: "foo_role", value: encoded_value, tweak: tweak, transformation: trans_name)
                expect(resp[:data][:decoded_value]).to eq(value)
              end
            end

            context "and a generated tweak source" do
              let(:tweak_source) { "generated" }

              it "encodes a value and decodes it to the original value" do
                resp = subject.transform.encode(role_name: "foo_role", value: value, transformation: trans_name)
                encoded_value = resp[:data][:encoded_value]
                generated_tweak = resp[:data][:tweak]
                expect(encoded_value).to match(template_regex)
                expect(encoded_value).not_to eq(value)
                resp = subject.transform.decode(role_name: "foo_role", value: encoded_value, tweak: generated_tweak, transformation: trans_name)
                expect(resp[:data][:decoded_value]).to eq(value)
              end
            end

            context "and an internal tweak source" do
              let(:tweak_source) { "internal" }

              it "encodes a value and decodes it to the original value" do
                resp = subject.transform.encode(role_name: "foo_role", value: value, transformation: trans_name)
                encoded_value = resp[:data][:encoded_value]
                expect(encoded_value).to match(template_regex)
                expect(encoded_value).not_to eq(value)
                resp = subject.transform.decode(role_name: "foo_role", value: encoded_value, transformation: trans_name)
                expect(resp[:data][:decoded_value]).to eq(value)
              end
            end
          end

          context "and a social security template" do
            let(:template_regex) { /\d{3}-\d{2}-\d{4}/ }
            let(:template) { "builtin/socialsecuritynumber" }
            let(:value) { "123-45-6789" }

            context "and a supplied tweak source" do
              let(:tweak_source) { "supplied" }

              it "encodes a value and decodes it to the original value" do
                resp = subject.transform.encode(role_name: "foo_role", value: value, tweak: tweak, transformation: trans_name)
                encoded_value = resp[:data][:encoded_value]
                expect(encoded_value).to match(template_regex)
                expect(encoded_value).not_to eq(value)
                resp = subject.transform.decode(role_name: "foo_role", value: encoded_value, tweak: tweak, transformation: trans_name)
                expect(resp[:data][:decoded_value]).to eq(value)
              end
            end

            context "and a generated tweak source" do
              let(:tweak_source) { "generated" }

              it "encodes a value and decodes it to the original value" do
                resp = subject.transform.encode(role_name: "foo_role", value: value, transformation: trans_name)
                encoded_value = resp[:data][:encoded_value]
                generated_tweak = resp[:data][:tweak]
                expect(encoded_value).to match(template_regex)
                expect(encoded_value).not_to eq(value)
                resp = subject.transform.decode(role_name: "foo_role", value: encoded_value, tweak: generated_tweak, transformation: trans_name)
                expect(resp[:data][:decoded_value]).to eq(value)
              end
            end

            context "and an internal tweak source" do
              let(:tweak_source) { "internal" }

              it "encodes a value and decodes it to the original value" do
                resp = subject.transform.encode(role_name: "foo_role", value: value, transformation: trans_name)
                encoded_value = resp[:data][:encoded_value]
                expect(encoded_value).to match(template_regex)
                expect(encoded_value).not_to eq(value)
                resp = subject.transform.decode(role_name: "foo_role", value: encoded_value, transformation: trans_name)
                expect(resp[:data][:decoded_value]).to eq(value)
              end
            end
          end
        end
        context "with a masking type" do
          let(:type) { "masking" }
          let(:tweak_source) { nil }

          context "and a credit card template" do
            let(:template_regex) { /\d{4}-\d{4}-\d{4}-\d{4}/ }
            let(:template) { "builtin/creditcardnumber" }
            let(:value) { "4111-1111-1111-1111"}

            it "encodes a value, providing the masked value" do
              resp = subject.transform.encode(role_name: "foo_role", value: value, transformation: trans_name)
              encoded_value = resp[:data][:encoded_value]
              expect(encoded_value).to eq("****-****-****-****")
            end
          end

          context "and a social security template" do
            let(:template_regex) { /\d{3}-\d{2}-\d{4}/ }
            let(:template) { "builtin/socialsecuritynumber" }
            let(:value) { "123-45-6789" }

            it "encodes a value, providing the masked value" do
              resp = subject.transform.encode(role_name: "foo_role", value: value, transformation: trans_name)
              encoded_value = resp[:data][:encoded_value]
              expect(encoded_value).to eq("***-**-****")
            end
          end
        end
      end
    end
  end
end
