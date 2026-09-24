import { describe, it, expect, vi, beforeEach } from "vitest";
import { screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import { WishEchoModal } from "./wish-echo-modal";

const fetchFlashbackAdminWishEchoes = vi.hoisted(() => vi.fn());
const createFlashbackWishEcho = vi.hoisted(() => vi.fn());
const updateFlashbackWishEchoDraft = vi.hoisted(() => vi.fn());
const publishFlashbackWishEcho = vi.hoisted(() => vi.fn());
const correctFlashbackWishEcho = vi.hoisted(() => vi.fn());
const revokeFlashbackWishEcho = vi.hoisted(() => vi.fn());

vi.mock("@/lib/admin", () => ({
  fetchFlashbackAdminWishEchoes,
  createFlashbackWishEcho,
  updateFlashbackWishEchoDraft,
  publishFlashbackWishEcho,
  correctFlashbackWishEcho,
  revokeFlashbackWishEcho,
}));

const WISH_ID = "w1";
const WISH_PREVIEW = "想再回到 2014 年的北京";

const draftEcho = {
  id: "e-draft",
  content: "第一版草稿",
  status: "draft" as const,
  insertedAt: "2026-09-24T08:00:00Z",
};
const publishedEcho = {
  id: "e-pub",
  content: "首条已发布回响",
  status: "published" as const,
  insertedAt: "2026-09-24T09:00:00Z",
  publishedAt: "2026-09-24T09:05:00Z",
};

const emptyResult = { echoes: [], currentNotifiableEndorsementCount: 3 };

beforeEach(() => {
  vi.clearAllMocks();
});

function renderModal(onChanged?: () => void) {
  return render(
    <WishEchoModal
      wishId={WISH_ID}
      wishPreview={WISH_PREVIEW}
      onClose={() => {}}
      onChanged={onChanged}
    />,
  );
}

describe("WishEchoModal（#835 愿望回响管理）", () => {
  it("空列表：空态 + 当前可通知附议数；新建草稿 trim 后提交", async () => {
    fetchFlashbackAdminWishEchoes.mockResolvedValue(emptyResult);
    createFlashbackWishEcho.mockResolvedValue({
      id: "e-new",
      content: "组织已定档",
      status: "draft",
      insertedAt: "2026-09-24T10:00:00Z",
    });

    renderModal();

    expect(
      await screen.findByText("暂无回响，可先建草稿。"),
    ).toBeInTheDocument();
    expect(screen.getByTestId("fb-echo-notifiable")).toHaveTextContent(
      "当前有 3 位附议者可接收回响通知。",
    );

    fireEvent.click(screen.getByText("新建草稿"));
    const save = screen.getByText("保存草稿");
    expect(save).toBeDisabled();
    fireEvent.change(screen.getByLabelText("回响正文"), {
      target: { value: "  组织已定档  " },
    });
    expect(save).toBeEnabled();
    fireEvent.click(save);

    await vi.waitFor(() =>
      expect(createFlashbackWishEcho).toHaveBeenCalledWith(
        WISH_ID,
        "组织已定档",
      ),
    );
  });

  it("超长禁用：正文超过 500 字时禁止提交", async () => {
    fetchFlashbackAdminWishEchoes.mockResolvedValue(emptyResult);

    renderModal();
    fireEvent.click(await screen.findByText("新建草稿"));

    fireEvent.change(screen.getByLabelText("回响正文"), {
      target: { value: "字".repeat(501) },
    });
    expect(screen.getByText("保存草稿")).toBeDisabled();
    expect(screen.getByRole("alert")).toBeInTheDocument();
  });

  it("草稿可编辑：编辑草稿调 update draft，不触发发布", async () => {
    fetchFlashbackAdminWishEchoes.mockResolvedValue({
      echoes: [draftEcho],
      currentNotifiableEndorsementCount: 0,
    });
    updateFlashbackWishEchoDraft.mockResolvedValue({
      ...draftEcho,
      content: "第二版草稿",
    });

    renderModal();
    fireEvent.click(await screen.findByText("编辑草稿"));
    fireEvent.change(screen.getByLabelText("回响正文"), {
      target: { value: "第二版草稿" },
    });
    fireEvent.click(screen.getByText("保存草稿"));

    await vi.waitFor(() =>
      expect(updateFlashbackWishEchoDraft).toHaveBeenCalledWith(
        draftEcho.id,
        "第二版草稿",
      ),
    );
    expect(publishFlashbackWishEcho).not.toHaveBeenCalled();
  });

  it("发布：确认框展示正文与「将尝试通知 5 位附议者」，确认后调 publish", async () => {
    fetchFlashbackAdminWishEchoes.mockResolvedValue({
      echoes: [draftEcho],
      currentNotifiableEndorsementCount: 5,
    });
    publishFlashbackWishEcho.mockResolvedValue({
      ...draftEcho,
      status: "published",
      publishedAt: "2026-09-24T10:05:00Z",
    });

    renderModal();
    fireEvent.click(await screen.findByText("发布"));

    expect(
      screen.getByText(/将尝试通知 5 位附议者（实际送达取决于对方的授权余额）/),
    ).toBeInTheDocument();
    expect(screen.getByTestId("fb-echo-confirm-preview")).toHaveTextContent(
      draftEcho.content,
    );
    fireEvent.click(screen.getByText("确认发布"));

    await vi.waitFor(() =>
      expect(publishFlashbackWishEcho).toHaveBeenCalledWith(draftEcho.id),
    );
  });

  it("更正：确认框写明不重新通知，提交新正文并标记已更正", async () => {
    fetchFlashbackAdminWishEchoes.mockResolvedValue({
      echoes: [publishedEcho],
      currentNotifiableEndorsementCount: 2,
    });
    correctFlashbackWishEcho.mockResolvedValue({
      ...publishedEcho,
      status: "corrected",
      content: "更正后的正文",
      correctedAt: "2026-09-24T11:00:00Z",
    });

    renderModal();
    fireEvent.click(await screen.findByText("更正"));

    expect(screen.getByText(/不会重新通知附议者/)).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("回响正文"), {
      target: { value: "更正后的正文" },
    });
    fireEvent.click(screen.getByText("确认更正"));

    await vi.waitFor(() =>
      expect(correctFlashbackWishEcho).toHaveBeenCalledWith(
        publishedEcho.id,
        "更正后的正文",
      ),
    );
  });

  it("撤回：确认框写明不可恢复且不通知，确认后调 revoke 并通知父级刷新", async () => {
    fetchFlashbackAdminWishEchoes.mockResolvedValue({
      echoes: [publishedEcho],
      currentNotifiableEndorsementCount: 7,
    });
    revokeFlashbackWishEcho.mockResolvedValue({
      ...publishedEcho,
      status: "revoked",
      revokedAt: "2026-09-24T12:00:00Z",
    });

    const onChanged = vi.fn();
    renderModal(onChanged);
    fireEvent.click(await screen.findByText("撤回"));

    expect(
      screen.getByText(/撤回后不可恢复，也不会通知附议者/),
    ).toBeInTheDocument();
    fireEvent.click(screen.getByText("确认撤回"));

    await vi.waitFor(() =>
      expect(revokeFlashbackWishEcho).toHaveBeenCalledWith(publishedEcho.id),
    );
    await vi.waitFor(() => expect(onChanged).toHaveBeenCalled());
  });

  it("提交失败：出现可读错误条，busy 释放后可再次提交", async () => {
    fetchFlashbackAdminWishEchoes.mockResolvedValue(emptyResult);
    createFlashbackWishEcho.mockRejectedValueOnce(new Error("boom"));

    renderModal();
    fireEvent.click(await screen.findByText("新建草稿"));
    fireEvent.change(screen.getByLabelText("回响正文"), {
      target: { value: "会失败" },
    });
    fireEvent.click(screen.getByText("保存草稿"));

    expect(await screen.findByText("操作失败，请重试。")).toBeInTheDocument();
    expect(screen.getByText("保存草稿")).toBeEnabled();
  });

  it("en 文案覆盖：发布确认框按 ICU 文案渲染，可通知人数注入", async () => {
    fetchFlashbackAdminWishEchoes.mockResolvedValue({
      echoes: [draftEcho],
      currentNotifiableEndorsementCount: 3,
    });

    render(
      <WishEchoModal
        wishId={WISH_ID}
        wishPreview={WISH_PREVIEW}
        onClose={() => {}}
      />,
      { locale: "en" },
    );

    fireEvent.click(await screen.findByText("Publish"));
    expect(
      screen.getByText(/will try to notify 3 endorser/i),
    ).toBeInTheDocument();
  });
});
