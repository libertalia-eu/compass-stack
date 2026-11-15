<#import "template.ftl" as layout>
<#import "buttons.ftl" as buttons>
<#import "social-providers.ftl" as identityProviders>
<#import "passkeys.ftl" as passkeys>
<#import "field.ftl" as field>
<#-- Copy of keycloak.v2 login.ftl with the fields written out (REQ-029): placeholder and icon instead of a visible label,
     the realm name in the title, the password toggle inside the field. Compare with the original on a Keycloak update. -->
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('username','password') displayInfo=realm.password && realm.registrationAllowed && !registrationDisabled??; section>
<!-- template: login.ftl (compass) -->

    <#if section = "header">
        <span class="compass-login-title">${msg("loginTitleFor", realm.displayName!realm.name)}</span>
    <#elseif section = "form">
        <div id="kc-form">
          <div id="kc-form-wrapper">
            <#if realm.password>
                <form id="kc-form-login" class="${properties.kcFormClass!}" onsubmit="login.disabled = true; return true;" action="${url.loginAction}" method="post" novalidate="novalidate">
                    <#if !usernameHidden??>
                        <#assign label><#if !realm.loginWithEmailAllowed>${msg("username")}<#elseif !realm.registrationEmailAsUsername>${msg("usernameOrEmail")}<#else>${msg("email")}</#if></#assign>
                        <#assign error = messagesPerField.getFirstError('username','password')>
                        <div class="${properties.kcFormGroupClass}">
                            <label for="username" class="compass-sr-only">${label}</label>
                            <span class="${properties.kcInputClass} compass-field <#if error?has_content>${properties.kcError}</#if>">
                                <i class="compass-icon compass-icon-user" aria-hidden="true"></i>
                                <input id="username" name="username" value="${login.username!''}" type="text" placeholder="${label}" autofocus
                                       autocomplete="${(enableWebAuthnConditionalUI?has_content)?then('username webauthn', 'username')}" aria-invalid="<#if error?has_content>true</#if>"/>
                            </span>
                            <div id="input-error-container-username">
                                <#if error?has_content>
                                    <div class="${properties.kcFormHelperTextClass}" aria-live="polite">
                                        <div class="${properties.kcInputHelperTextClass}">
                                            <div class="${properties.kcInputHelperTextItemClass} ${properties.kcError}" id="input-error-username">
                                                <span class="${properties.kcInputErrorMessageClass}">${error}</span>
                                            </div>
                                        </div>
                                    </div>
                                </#if>
                            </div>
                        </div>
                    </#if>
                    <div class="${properties.kcFormGroupClass}">
                        <label for="password" class="compass-sr-only">${msg("password")}</label>
                        <span class="${properties.kcInputClass} compass-field">
                            <i class="compass-icon compass-icon-lock" aria-hidden="true"></i>
                            <input id="password" name="password" type="password" placeholder="${msg("password")}" <#if usernameHidden??>autofocus</#if>
                                   autocomplete="current-password" aria-invalid=""/>
                            <button class="${properties.kcFormPasswordVisibilityButtonClass}" type="button" aria-label="${msg('showPassword')}"
                                    aria-controls="password" data-password-toggle
                                    data-icon-show="${properties.kcFormPasswordVisibilityIconShow}" data-icon-hide="${properties.kcFormPasswordVisibilityIconHide}"
                                    data-label-show="${msg('showPassword')}" data-label-hide="${msg('hidePassword')}" id="password-show-password">
                                <i class="${properties.kcFormPasswordVisibilityIconShow}" aria-hidden="true"></i>
                            </button>
                        </span>
                        <#if realm.resetPasswordAllowed>
                            <div class="${properties.kcFormHelperTextClass}" aria-live="polite">
                                <div class="${properties.kcInputHelperTextClass}">
                                    <div class="${properties.kcInputHelperTextItemClass}">
                                        <span class="${properties.kcInputHelperTextItemTextClass}">
                                            <a href="${url.loginResetCredentialsUrl}">${msg("doForgotPassword")}</a>
                                        </span>
                                    </div>
                                </div>
                            </div>
                        </#if>
                        <#if realm.rememberMe && !usernameHidden??>
                            <@field.checkbox name="rememberMe" label=msg("rememberMe") value=login.rememberMe?? />
                        </#if>
                    </div>

                    <input type="hidden" id="id-hidden-input" name="credentialId" <#if auth.selectedCredential?has_content>value="${auth.selectedCredential}"</#if>/>
                    <@buttons.loginButton />
                </form>
            </#if>
            </div>
        </div>
        <@passkeys.conditionalUIData />
    <#elseif section = "socialProviders" >
        <#if realm.password && social.providers?? && social.providers?has_content>
            <@identityProviders.show social=social/>
        </#if>
    <#elseif section = "info" >
        <#if realm.password && realm.registrationAllowed && !registrationDisabled??>
            <div id="kc-registration-container">
                <div id="kc-registration">
                    <span>${msg("noAccount")} <a href="${url.registrationUrl}">${msg("doRegister")}</a></span>
                </div>
            </div>
        </#if>
    </#if>

</@layout.registrationLayout>
