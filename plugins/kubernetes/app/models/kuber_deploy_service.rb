require 'kubeclient'

class KuberDeployService
  attr_reader :kuber_release

  delegate :build, to: :kuber_release

  def initialize(kuber_release)
    @kuber_release = kuber_release
  end

  def deploy!
    # TODO: handling different deploy strategies (rolling updates, etc.)
    log 'starting deploy'

    create_services!
    create_replication_controllers!

    Watchers::DeployWatcher.new(@kuber_release).async :watch

    log 'API requests complete'
    publish_fake_updates
  rescue => ex
    Rails.logger.warn "*********** Couldn't deploy: #{ex.message}"
    raise ex
  end

  def create_replication_controllers!
    kuber_release.release_docs.each do |release_doc|
      log 'creating ReplicationController', role: release_doc.kubernetes_role.name
      release_doc.deploy_to_kubernetes
    end
  end

  def create_services!
    kuber_release.release_docs.each do |release_doc|
      role = release_doc.kubernetes_role
      service = release_doc.service

      if service.nil?
        log 'no Service defined', role: role.name
      elsif service.running?
        log 'Service already running', role: role.name, service_name: service.name
      else
        log 'creating Service', role: role.name, service_name: service.name
        release_doc.client.create_service(Kubeclient::Service.new(release_doc.service_hash))
      end
    end
  end

  def project
    @project ||= kuber_release.project
  end

  private

  # TODO: Remove this dummy data when proper watchers created.
  def publish_fake_updates
    @kuber_release.release_docs.each do |release_doc|
      sleep 2
      Rails.logger.info "************ Send fake update for #{release_doc.replication_controller_name} - #{release_doc.kubernetes_role.name}"
      Celluloid::Notifications.publish("#{release_doc.replication_controller_name}",
              object: {
                metadata: {
                  name: release_doc.replication_controller_name,
                },
                spec: {
                  replicas: release_doc.replica_target,
                },
                status: {
                  replicas: release_doc.replica_target,
                }
              }
      )
    end
  end

  def log(msg, extra_info = {})
    extra_info.merge!(
      release: kuber_release.id,
      project: project.name
    )

    Kubernetes::Util.log msg, extra_info
  end
end
