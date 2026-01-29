# frozen_string_literal: true

class UsersController < ApplicationController
  before_action :set_user, only: [:show, :update]

  # GET /users
  def index
    @users = User.includes(:organization).all.order(created_at: :desc)
    render json: @users, include: :organization
  end

  # GET /users/:id
  def show
    render json: @user, include: :organization
  end

  # POST /users
  def create
    @user = User.new(user_params)

    if @user.save
      render json: @user, status: :created
    else
      render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /users/:id
  def update
    if @user.update(user_params)
      render json: @user
    else
      render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def set_user
    @user = User.find(params[:id])
  end

  def user_params
    params.require(:user).permit(:organization_id, :name, :email, :role, :active)
  end
end
