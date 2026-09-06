defmodule Cgc2046.Learning.TeachingProjection do
  @moduledoc """
  Tutor/Owner/Admin course projection with no learner evidence text.
  """

  alias Cgc2046.Learning.Analytics

  def for_course(course), do: Analytics.for_course(course)
end
