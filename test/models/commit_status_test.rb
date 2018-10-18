# frozen_string_literal: true
require_relative '../test_helper'

SingleCov.covered! uncovered: 1

describe CommitStatus do
  def self.deploying_a_previous_release
    let(:reference) { 'v4.2' }
    let(:deploy) { deploys(:succeeded_production_test) }

    before do
      DeployGroup.stubs(enabled?: true)
      dg = deploy_groups(:pod1)
      dg.update_column(:environment_id, environments(:staging).id)
      stage.deploy_groups << dg
      deploy.update_column(:reference, 'v4.3')
    end
  end

  def success!
    stub_github_api(url, statuses: [{foo: "bar", updated_at: 1.day.ago}], state: "success")
  end

  def failure!
    stub_github_api(url, nil, 404)
  end

  def status(stage_param: stage, reference_param: reference)
    CommitStatus.new(stage_param.project, reference_param, stage: stage_param)
  end

  let(:stage) { stages(:test_staging) }
  let(:reference) { 'master' }
  let(:url) { "repos/#{stage.project.repository_path}/commits/#{reference}/status" }

  describe "#state" do
    it "returns state" do
      success!
      status.state.must_equal 'success'
    end

    it "is missing when not found" do
      failure!
      status.state.must_equal 'missing'
    end

    it "works without stage" do
      success!
      s = status
      s.instance_variable_set(:@stage, nil)
      s.state.must_equal "success"
    end

    it "does not cache changing references" do
      request = success!
      status.state.must_equal 'success'
      status.state.must_equal 'success'
      assert_requested request, times: 2
    end

    describe "caching static references" do
      let(:reference) { 'v4.2' }

      it "caches github state accross instances" do
        request = success!
        status.state.must_equal 'success'
        status.state.must_equal 'success'
        assert_requested request, times: 1
      end

      it "can expire cache" do
        request = success!
        status.state.must_equal 'success'
        status.expire_cache reference
        status.state.must_equal 'success'
        assert_requested request, times: 2
      end
    end

    describe "when deploying a previous release" do
      deploying_a_previous_release

      it "warns" do
        success!
        assert_sql_queries 10 do
          status.state.must_equal 'error'
        end
      end

      it "warns when an older deploy has a lower version (grouping + ordering test)" do
        deploys(:succeeded_test).update_column(:stage_id, deploy.stage_id) # need 2 successful deploys on the same stage
        deploys(:succeeded_test).update_column(:reference, 'v4.1') # old is lower
        deploy.update_column(:reference, 'v4.3') # new is higher
        success!
        status.state.must_equal 'error'
      end

      it "ignores when previous deploy was the same or lower" do
        deploy.update_column(:reference, reference)
        success!
        status.state.must_equal 'success'
      end

      describe "when previous deploy was higher numerically" do
        before { deploy.update_column(:reference, 'v4.10') }

        it "warns" do
          success!
          status = status()
          status.state.must_equal 'error'
          status.statuses[1][:description].must_equal(
            "v4.10 was deployed to deploy groups in this stage by Production"
          )
        end

        it "warns with multiple higher deploys" do
          other = deploys(:succeeded_test)
          other.update_column(:reference, 'v4.9')

          success!
          status = status()
          status.state.must_equal 'error'
          status.statuses[1][:description].must_equal(
            "v4.9, v4.10 was deployed to deploy groups in this stage by Staging, Production"
          )
        end
      end

      it "ignores when previous deploy was not a version" do
        deploy.update_column(:reference, 'master')
        success!
        status.state.must_equal 'success'
      end

      it "ignores when previous deploy was failed" do
        deploy.job.update_column(:status, 'faild')
        success!
        status.state.must_equal 'success'
      end
    end
  end

  describe "#statuses" do
    it "returns list" do
      success!
      status.statuses.map { |s| s[:foo] }.must_equal ["bar"]
    end

    it "shows that github is waiting for statuses to come when non has arrived yet ... or none are set up" do
      stub_github_api(url, statuses: [], state: "pending")
      list = status.statuses
      list.map { |s| s[:state] }.must_equal ["pending"]
      list.first[:description].must_include "No status was reported"
    end

    it "returns Reference context for release/show display" do
      failure!
      status.statuses.map { |s| s[:context] }.must_equal ["Reference"]
    end

    describe "when deploying a previous release" do
      deploying_a_previous_release

      it "merges" do
        success!
        status.statuses.each { |s| s.delete(:updated_at) }.must_equal [
          {foo: "bar"},
          {state: "Old Release", description: "v4.3 was deployed to deploy groups in this stage by Production"}
        ]
      end
    end
  end

  describe '#ref_statuses' do
    let(:production_stage) { stages(:test_production) }

    it 'returns nothing if stage is not production' do
      status.send(:ref_statuses).must_equal []
    end

    it 'returns nothing if ref has been deployed to non-production stage' do
      production_stage.project.expects(:deployed_reference_to_non_production_stage?).returns(true)

      status(stage_param: production_stage).send(:ref_statuses).must_equal []
    end

    it 'returns status if ref has not been deployed to non-production stage' do
      production_stage.project.expects(:deployed_reference_to_non_production_stage?).returns(false)

      expected_hash = [
        {
          state: "pending",
          statuses: [
            {
              state: "Production Only Reference",
              description: "master has not been deployed to a non-production stage."
            }
          ]
        }
      ]

      status(stage_param: production_stage).send(:ref_statuses).must_equal expected_hash
    end

    it 'includes plugin statuses' do
      Samson::Hooks.expects(:fire).with(:ref_status, stage, reference).returns([{foo: :bar}])

      status.send(:ref_statuses).must_equal [{foo: :bar}]
    end
  end

  describe "#cache_fetch_if" do
    it "fetches old" do
      Rails.cache.write('a', 1)
      status.send(:cache_fetch_if, true, 'a', expires_in: :raise) { 2 }.must_equal 1
    end

    it "does not cache when not requested" do
      Rails.cache.write('a', 1)
      status.send(:cache_fetch_if, false, 'a', expires_in: :raise) { 2 }.must_equal 2
      Rails.cache.read('a').must_equal 1
    end

    it "caches with expiration" do
      status.send(:cache_fetch_if, true, 'a', expires_in: ->(_) { 1 }) { 2 }.must_equal 2
      Rails.cache.read('a').must_equal 2
    end
  end

  describe "#cache_duration" do
    it "is short when we do not know if the commit is new or old" do
      status.send(:cache_duration, statuses: []).must_equal 5.minutes
    end

    it "is long when we do not expect new updates" do
      status.send(:cache_duration, statuses: [{updated_at: 1.day.ago}]).must_equal 1.day
    end

    it "is short when we expect updates shortly" do
      status.send(:cache_duration, statuses: [{updated_at: 10.minutes.ago, state: "pending"}]).must_equal 1.minute
    end
    it "is medium when some status might still be changing or coming in late" do
      status.send(:cache_duration, statuses: [{updated_at: 10.minutes.ago, state: "success"}]).must_equal 10.minutes
    end
  end
end
