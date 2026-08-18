import { useTranslations } from "next-intl";
import {
  ROLE_BADGE_CLASS,
  ROLE_LABEL,
  type MembershipRoleName,
} from "@/lib/graphql/workspace";

export function roleLabel(role: MembershipRoleName) {
  return ROLE_LABEL[role] ?? role;
}

export function roleBadgeClass(role: MembershipRoleName) {
  return ROLE_BADGE_CLASS[role] ?? "l-badge";
}

export function RoleChips({
  roles,
  className = "",
}: {
  roles: MembershipRoleName[];
  className?: string;
}) {
  const t = useTranslations("workspace");
  return (
    <div className={`profile-role-chips ${className}`}>
      {roles.length > 0 ? (
        roles.map((role) => (
          <span key={role} className={roleBadgeClass(role)}>
            {roleLabel(role)}
          </span>
        ))
      ) : (
        <span className="profile-role-empty">{t("roleEmpty")}</span>
      )}
    </div>
  );
}
