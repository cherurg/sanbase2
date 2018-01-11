defmodule Sanbase.ExAdmin.Model.ProjectBtcAddress do
  use ExAdmin.Register

  import Ecto.Query, warn: false

  alias Sanbase.Model.Project

  register_resource Sanbase.Model.ProjectBtcAddress do
    form project do
      inputs do
        input project, :address
        input project, :project, collection: from(p in Project, order_by: p.name) |> Sanbase.Repo.all()
        input project, :project_transparency
      end
    end
  end
end
