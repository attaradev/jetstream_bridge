# frozen_string_literal: true

class OrganizationsController < ApplicationController
  before_action :set_organization, only: [:show, :update]

  # GET /organizations
  def index
    @organizations = Organization.all.order(created_at: :desc)
    render json: @organizations
  end

  # GET /organizations/:id
  def show
    render json: @organization
  end

  # POST /organizations
  def create
    @organization = Organization.new(organization_params)

    if @organization.save
      render json: @organization, status: :created
    else
      render json: { errors: @organization.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /organizations/:id
  def update
    if @organization.update(organization_params)
      render json: @organization
    else
      render json: { errors: @organization.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def set_organization
    @organization = Organization.find(params[:id])
  end

  def organization_params
    params.require(:organization).permit(:name, :domain, :active)
  end
end
